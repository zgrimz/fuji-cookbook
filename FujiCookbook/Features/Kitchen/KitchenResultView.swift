import SwiftData
import SwiftUI
import UIKit

/// Shows what a cook produced: a preview of each developed JPEG with Save to Photos and Share, and
/// a row for each failure. Camera Test runs show it from Develop and Test Kitchen alike; outside the
/// test, Develop shows it only when nothing was filed to Recent Results — every develop failed, or
/// the store refused the batch and the recovery copies are all there is.
struct KitchenResultView: View {
    let results: [ConversionResult]
    var onContinueTest: (() -> Void)?
    var onReportTest: (() -> Void)?
    var savedBatchID: UUID?
    var saveFailed = false
    var resultLabels: [UUID: String] = [:]
    var resultGuidance: [UUID: String] = [:]
    var onRetryTest: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    /// Gates the raw D185 profile dump — see `DiagnosticMode`.
    @AppStorage(DiagnosticMode.key) private var diagnosticMode = false

    @State private var shareItem: ShareItem?
    @State private var saver = ImageSaver()
    @State private var saveMessage: String?
    @State private var savedConfirmation: String?
    /// A display proxy per developed result, decoded off the main actor from bytes read on demand
    /// and let go. The sheet follows a batch of full-resolution develops, 25.7 MB each on the X-T50
    /// (zgrimz/fujifilm-ptp-reference `docs/05-raw-conversion.md`), and `UIImage(data:)` would keep
    /// every one of them alive behind its image.
    @State private var images: [UUID: UIImage] = [:]
    /// Results whose preview has been tried, decoded or not, so a failed decode reads as one.
    @State private var attempted: Set<UUID> = []

    /// Long edge of the display proxies: the same compromise `ComparisonImageStore` makes, above a
    /// phone's pixel width and far below a 40MP develop.
    nonisolated private static let proxyLongEdge: CGFloat = 2048

    private var successes: [ConversionResult] { results.filter { $0.success && $0.recoveryFileURL != nil } }
    private var failures: [ConversionResult] { results.filter { !$0.success } }

    var body: some View {
        List {
            if successes.isEmpty && failures.isEmpty {
                ContentUnavailableView("Nothing developed", systemImage: "frying.pan")
                    .cardRowBackground()
            }

            ForEach(successes) { result in
                Section {
                    if let guidance = resultGuidance[result.id], !guidance.isEmpty {
                        Text(guidance).font(.subheadline).foregroundStyle(Theme.ink2)
                    }
                    preview(for: result)

                    if !result.clampedFields.isEmpty {
                        Label("Adjusted before developing: \(result.clampedFields.joined(separator: ", "))",
                              systemImage: "slider.horizontal.below.rectangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(result.notes, id: \.self) { note in
                        Label(note, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(result.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Theme.warning)
                    }

                    Button { save(result) } label: {
                        Label("Save to Photos", systemImage: "square.and.arrow.down")
                    }
                    Button { share(result) } label: {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                    if saveFailed, let recovered = result.recoveryFileURL {
                        ShareLink(item: recovered) {
                            Label("Export saved recovery copy…", systemImage: "doc.badge.arrow.up")
                        }
                    }
                    diagnosticsView(result.diagnostics)
                } header: {
                    Text(resultLabels[result.id].map { "\($0) · \(result.outputFilename)" } ?? result.outputFilename)
                }
            }
            .cardRowBackground()

            if !successes.isEmpty {
                Section {
                    if onContinueTest != nil {
                        Text("Inspect the photo, then tap Continue Camera Test to record what you saw. Choose Didn't check if you cannot judge it.")
                            .font(.subheadline).foregroundStyle(Theme.ink2)
                    }
                    if let savedBatchID {
                        NavigationLink("View saved results") {
                            SavedComparisonsView(batchID: savedBatchID)
                        }
                    }
                } footer: {
                    Text(saveFailed
                         ? "Saving to Recent Results failed. A recovery copy is kept in the app's Recovered Develops folder. You can save or export it above."
                         : "Kept in Recent Results in the Kitchen — closing this doesn't discard them.")
                }
                .cardRowBackground()
            }

            if !failures.isEmpty {
                Section("Couldn't Develop") {
                    ForEach(failures) { result in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(resultLabels[result.id].map { "\($0) · \(result.sourceFilename)" } ?? result.sourceFilename).font(.headline)
                            Text(result.errorMessage ?? "Unknown error")
                                .font(.subheadline).foregroundStyle(.secondary)
                            diagnosticsView(result.diagnostics)
                        }
                    }
                    if let onRetryTest {
                        Button("Try again") {
                            dismiss()
                            onRetryTest()
                        }
                    }
                    // Ungated, and here rather than only at the foot of the Develop screen: this is
                    // where a tester is standing when a develop fails, and the cause is already in
                    // the report's log.
                    if let onReportTest {
                        Button("Share Camera Test progress", action: onReportTest)
                    } else {
                        ReportProblemRow(prompt: ReportProblemRow.kitchenPrompt)
                    }
                }
                .cardRowBackground()
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle(Self.title(developed: successes.count, of: results.count))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(onContinueTest == nil ? "Done" : "Continue Camera Test") {
                    dismiss()
                    onContinueTest?()
                }
            }
        }
        .photoExportPresentation(share: $shareItem, message: $saveMessage)
        .confirmationToast($savedConfirmation)
        .task { await loadImages() }
    }

    /// "Developed", "3 Developed", or "2 of 3 Developed" when some failed, so a partial run never
    /// reads as a whole one.
    static func title(developed: Int, of total: Int) -> String {
        if developed == 0 { return "Develop failed" }
        if developed < total { return "\(developed) of \(total) Developed" }
        return developed > 1 ? "\(developed) Developed" : "Developed"
    }

    @ViewBuilder
    private func preview(for result: ConversionResult) -> some View {
        if let image = images[result.id] {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .listRowInsets(EdgeInsets())
                .accessibilityLabel("Developed photo of \(result.sourceFilename)")
        } else if attempted.contains(result.id) {
            Label("This photo can't be previewed here. Save or share it to see it.", systemImage: "photo")
                .font(.footnote)
                .foregroundStyle(Theme.ink2)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 160)
                .accessibilityLabel("Loading the photo")
        }
    }

    @ViewBuilder
    private func diagnosticsView(_ text: String?) -> some View {
        if let text, diagnosticMode {
            DiagnosticsDisclosure(text: text)
        }
    }

    // MARK: Images

    /// One result at a time: read its bytes, decode the proxy off the main actor, drop the bytes.
    private func loadImages() async {
        for result in successes where images[result.id] == nil {
            defer { attempted.insert(result.id) }
            guard let jpeg = try? await CookStore.developedJPEG(for: result, in: modelContext) else { continue }
            let proxy = await Task.detached(priority: .userInitiated) {
                FrameRenderer.proxy(from: jpeg, maxLongEdge: Self.proxyLongEdge)
            }.value
            if let proxy { images[result.id] = proxy }
        }
    }

    // MARK: Actions

    private func save(_ result: ConversionResult) {
        Task {
            do {
                guard let jpeg = try await CookStore.developedJPEG(for: result, in: modelContext) else { return }
                // Save the original developed JPEG bytes so EXIF (camera, exposure, capture date…) is kept.
                saver.save(data: jpeg) { error in
                    if let error { saveMessage = ImageSaver.message(for: error) } else { savedConfirmation = "Saved to Photos" }
                }
            } catch {
                saveMessage = ImageSaver.message(for: error)
            }
        }
    }

    /// Write the JPEG to a temp file so the share sheet carries a sensible filename, then present it.
    private func share(_ result: ConversionResult) {
        Task {
            do {
                guard let jpeg = try await CookStore.developedJPEG(for: result, in: modelContext) else { return }
                shareItem = try .temporaryFiles([(jpeg, result.outputFilename)])
            } catch {
                saveMessage = ShareItem.preparationFailure(error)
            }
        }
    }
}
