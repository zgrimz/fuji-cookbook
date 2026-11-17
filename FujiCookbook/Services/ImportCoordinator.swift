import Foundation
import Observation

/// A batch of recipes awaiting the user's duplicate decisions before they enter the library.
struct PendingImport: Identifiable {
    let id = UUID()
    let recipes: [PortableRecipe]
    /// Chapters carried by a full backup; empty for a plain recipe file.
    let chapters: [PortableChapter]
    /// Where the file came from, for the review sheet's title.
    let sourceName: String
    var preparedRecipes: [PreparedRecipe]? = nil
    /// Retained by both the pending import and its review sheet until all selected writes finish.
    var staging: RecipeImportStaging? = nil
}

/// Turns incoming recipes into a review: files opened from Files, Mail, Messages or the share sheet,
/// screenshots the Share Extension queued, and recipes pasted as text. A file that fails preparation
/// surfaces an error and imports nothing.
@MainActor
@Observable
final class ImportCoordinator {
    var pendingImport: PendingImport?
    var importError: String?
    private(set) var isPreparingImport = false
    private(set) var importProgress: RecipeImportPreparation.Progress?

    typealias Preparer = (RecipeImportPreparation.Input, RecipeImportPreparation.ProgressHandler) throws -> PreparedRecipeImport
    typealias ScreenshotScanner = (_ imageData: Data, _ provider: AIProvider, _ apiKey: String,
                                   _ modelID: String) async throws -> PortableRecipe
    @ObservationIgnored private let prepare: Preparer
    @ObservationIgnored private let scanScreenshot: ScreenshotScanner
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var importID = UUID()

    init(prepare: @escaping Preparer = { input, progress in
        try RecipeImportPreparation.prepare(input, progress: progress)
    }, scanScreenshot: @escaping ScreenshotScanner = { imageData, provider, apiKey, modelID in
        try await RecipeScanner.scan(imageData: imageData, provider: provider, apiKey: apiKey, modelID: modelID)
    }) {
        self.prepare = prepare
        self.scanScreenshot = scanScreenshot
    }

    @discardableResult
    func load(url: URL) -> Task<Void, Never> {
        start(.file(url), sourceName: url.lastPathComponent)
    }

    @discardableResult
    func load(data: Data, sourceName: String) -> Task<Void, Never> {
        start(.data(data), sourceName: sourceName)
    }

    func cancelImport() {
        importID = UUID()
        preparationTask?.cancel()
        preparationTask = nil
        isPreparingImport = false
        importProgress = nil
    }

    private func start(_ input: RecipeImportPreparation.Input, sourceName: String) -> Task<Void, Never> {
        cancelImport()
        pendingImport = nil
        importError = nil
        isPreparingImport = true
        let id = importID
        let prepare = prepare
        let worker = Task.detached(priority: .userInitiated) { [weak self] in
            try Task.checkCancellation()
            return try prepare(input) { progress in
                Task { @MainActor [weak self] in
                    guard let self, self.importID == id, self.isPreparingImport else { return }
                    self.importProgress = progress
                }
            }
        }
        let task = Task { [weak self] in
            do {
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard let self, self.importID == id, !Task.isCancelled else { return }
                self.pendingImport = PendingImport(recipes: result.recipes.map(\.recipe),
                                                   chapters: result.chapters, sourceName: sourceName,
                                                   preparedRecipes: result.recipes, staging: result.staging)
            } catch is CancellationError {
                // Cancellation is an ordinary choice, not an import error.
            } catch {
                guard let self, self.importID == id, !Task.isCancelled else { return }
                if let fileError = error as? RecipeFileError {
                    AppLog.error(.importExport, "Import rejected the file — \(fileError.diagnosticReason)")
                    self.importError = fileError.errorDescription
                } else {
                    AppLog.error(.importExport, "Import failed — \(AppLog.bounded(error))")
                    self.importError = "Couldn't prepare “\(sourceName)”: \(error.localizedDescription)"
                }
            }
            guard let self, self.importID == id else { return }
            self.isPreparingImport = false
            self.importProgress = nil
            self.preparationTask = nil
        }
        preparationTask = task
        return task
    }

    // MARK: Shared-screenshot inbox (Share Extension fallback)

    /// True while shared screenshots are being scanned, for a progress overlay.
    private(set) var isScanningSharedScreenshots = false

    /// Warn about missing AI setup at most once per app launch, so a waiting screenshot doesn't
    /// nag on every foreground until the user adds a key.
    private var warnedAboutScanSetup = false

    @ObservationIgnored private var sharedScreenshotScan: Task<Void, Never>?

    /// Drain the inbox in a task the coordinator owns, for a caller that can't wait for it. Does
    /// nothing while an earlier one is still running.
    func startSharedScreenshotScan(using ai: AISettings) {
        guard sharedScreenshotScan == nil else { return }
        sharedScreenshotScan = Task {
            await processSharedScreenshots(using: ai)
            sharedScreenshotScan = nil
        }
    }

    /// Drain the ``ScreenshotInbox``: scan every screenshot the Share Extension queued and present
    /// the results through the same review sheet as a file import. Called on launch and on each
    /// return to the foreground.
    ///
    /// The fallback path: the extension scans and saves on its own, and queues a file only when it
    /// couldn't (AI not set up, a failed scan, a wait the user cut short, or a synced store the
    /// extension mustn't write). Files survive a missing configuration and a failed scan. A scanned
    /// file is removed when its review is presented; if a newer import took the review first, the
    /// file stays for the next attempt. ``ScreenshotInbox/purgeStale(now:)`` bounds how long any
    /// file stays, and one attempt per foreground bounds the cost.
    func processSharedScreenshots(using ai: AISettings) async {
        guard !isScanningSharedScreenshots, !isPreparingImport, pendingImport == nil else { return }
        let waiting = ScreenshotInbox.pending()
        guard !waiting.isEmpty else { return }

        guard ai.isConfigured else {
            if !warnedAboutScanSetup {
                warnedAboutScanSetup = true
                importError = "A shared screenshot is waiting to be scanned, but AI scanning isn't set up. Turn on AI features in Settings and add your \(ai.provider.displayName) API key, and it will be read the next time you open the app."
            }
            return
        }

        isScanningSharedScreenshots = true
        defer { isScanningSharedScreenshots = false }
        let scanImportID = importID

        var recipes: [PortableRecipe] = []
        var scannedURLs: [URL] = []
        var lastError: String?
        for url in waiting {
            guard let data = try? Data(contentsOf: url) else {
                ScreenshotInbox.remove(url)
                continue
            }
            do {
                recipes.append(try await scanScreenshot(data, ai.provider, ai.apiKey, ai.modelID))
                scannedURLs.append(url)
            } catch {
                AppLog.error(.ai, "Shared-screenshot scan failed — \((error as? RecipeScanError)?.diagnosticReason ?? "other")")
                lastError = error.localizedDescription
                // Kept for the next foreground: the user asked for this file to be held.
            }
        }

        // A file opened while the network call was running owns the review now. Leave the inbox
        // copies in place instead of losing the scan or overwriting a newer import's review.
        guard importID == scanImportID, !isPreparingImport, pendingImport == nil else { return }
        if !recipes.isEmpty {
            scannedURLs.forEach(ScreenshotInbox.remove)
            pendingImport = PendingImport(recipes: recipes, chapters: [],
                                          sourceName: recipes.count == 1 ? "Shared Screenshot"
                                                                         : "Shared Screenshots")
        } else if let lastError {
            importError = lastError
        }
    }
}

// MARK: - Pasted text

/// A recipe read from pasted text that passed the checks a file import makes. Only
/// ``ImportCoordinator/readPastedText(_:)`` makes one, so ``ImportCoordinator/review(_:)`` is never
/// handed an unchecked recipe.
struct PastedRecipe {
    let recipe: PortableRecipe

    fileprivate init(recipe: PortableRecipe) {
        self.recipe = recipe
    }
}

extension ImportCoordinator {
    static let pastedTextSourceName = "Pasted Text"

    /// Reads a recipe out of pasted text and checks it the way a file import is checked. Throws
    /// `RecipeTextParseError` when the text holds no recipe or a number import refuses. Opens
    /// nothing, so the caller can show the error beside the text.
    nonisolated static func readPastedText(_ text: String) throws -> PastedRecipe {
        let recipe = try RecipeTextParser.parse(text)
        do {
            try RecipeImportValidation.validate(.single(recipe), limits: .standard)
        } catch RecipeFileError.unsafeNumber(_, let field) {
            throw RecipeTextParseError.unsafeNumber(field: field)
        }
        return PastedRecipe(recipe: recipe)
    }

    /// Opens the review for a recipe read from pasted text, in place of a file still being
    /// prepared. A review already open is left alone and the paste is refused with an error, as a
    /// shared screenshot's scan is held back (``processSharedScreenshots(using:)``).
    func review(_ pasted: PastedRecipe) {
        guard pendingImport == nil, !isScanningSharedScreenshots else {
            importError = "Another import is waiting for review. Finish it, then paste the recipe again."
            return
        }
        cancelImport()
        importError = nil
        pendingImport = PendingImport(recipes: [pasted.recipe], chapters: [],
                                      sourceName: Self.pastedTextSourceName)
    }
}
