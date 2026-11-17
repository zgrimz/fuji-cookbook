import Foundation
import Observation

/// Develops RAW files on the camera itself (the Kitchen): the camera's own processor renders the
/// RAF, with the recipe written into its conversion profile (`0xD185`). Also runs the Camera Test's
/// profile harvest and the D185 dynamic-range probe, which share the develop's upload and profile
/// read.
///
/// The flow is split in two: **upload once, develop many**. Getting a RAF into the camera's
/// conversion buffer (87 MB from an X-T50, 198 MiB from a GFX100S; `RAFSource` cites the record) is
/// by far the slowest step, and the buffer survives a conversion, so re-triggering with a new
/// profile is all another version of the same photo needs (zgrimz/fujifilm-ptp-reference
/// `docs/05-raw-conversion.md#upload-once-develop-many`). That is what makes the Test Kitchen's
/// grid three uploads instead of nine.
@MainActor
@Observable
final class RawConversionService {

    /// Live batch-conversion progress, published during `cookBatch` and `cookMatrix`.
    private(set) var conversionProgress: BatchProgress?

    private let session: CameraSession
    private let reports: CompatibilityReportRecorder
    private let gate: CameraOperationGate

    init(session: CameraSession, reports: CompatibilityReportRecorder, gate: CameraOperationGate) {
        self.session = session
        self.reports = reports
        self.gate = gate
    }

    func reset() {
        conversionProgress = nil
    }

    // MARK: - Recording

    /// Record a probe or harvest finding in the shared compatibility report and persist it, so the
    /// finding outlives the screen that ran it.
    private func noteInCompatibilityReport(_ text: String) {
        reports.note(text)
        reports.persist()
    }

    /// Record one develop in the shared compatibility report and persist it, as a push is recorded.
    private func recordCook(_ result: ConversionResult, at: Date, filmSimulation: String?,
                            context: CookRecordContext? = nil) {
        reports.update { $0.record(develop: result.evidence, at: at,
                                   modelID: session.connected?.registryModel?.id,
                                   firmwareVersion: session.connected?.firmwareVersion,
                                   succeeded: result.success,
                                   clampedFields: result.clampedFields,
                                   filmSimulation: filmSimulation,
                                   resultID: result.id, context: context) }
        reports.persist()
    }

    /// Record one profile harvest and persist it.
    private func recordHarvest(_ record: CameraCompatibilityReport.ProfileHarvestRecord) {
        reports.update { $0.record(harvest: record) }
        reports.persist()
    }


    /// A RAF sitting in the camera's conversion buffer, plus the conversion profile read back after
    /// the upload — which is when it reflects that photo's as-shot settings.
    ///
    /// `base` is captured once and every recipe is patched onto *this* copy. Re-reading `0xD185`
    /// between versions would compound the previous patch instead of starting from the photo's own
    /// values.
    struct LoadedRAF {
        let filename: String
        let base: Data
        let layout: FujiRawConvProfile.Layout
        let sessionEpoch: UInt64
        /// Established at upload time and carried, not recomputed: the Test Kitchen develops one
        /// upload many times, and the profile's shape is a fact about the *body*, not the version.
        var evidence = CookEvidence()
    }

    /// A RAF that never made it into the buffer — or whose profile we refused to patch. Carries the
    /// D185 evidence, which for a layout failure is the only thing that can characterise an
    /// unfamiliar body.
    private struct LoadFailure: Error {
        let message: String
        let diagnostics: String?
        /// Coarse, non-identifying label for the log line. Carried alongside `message` rather than
        /// derived from it: the message is user-facing prose that interpolates file names, which
        /// must never reach the log.
        var reason: String = "load_failed"
        /// What the load learned before it gave up. A `conversion_profile_mismatch` on an
        /// unfamiliar body carries the profile length, which is the whole finding.
        var evidence = CookEvidence()
        /// The upload may have landed without a valid completion. Do not start another upload.
        var requiresReconnect = false
    }

    /// Convert one RAF through the camera: upload the RAW, apply the recipe via the `0xD185` profile,
    /// trigger conversion (`0xD183`), then retrieve and return the produced JPEG. The camera does the
    /// actual rendering — we only move bytes and patch the profile.
    ///
    /// `progress` is an optional "(2 of 5) " prefix so a batch can report position in status messages.
    ///
    /// `fullResolution` selects the `0xD183` trigger value: `1` develops at full resolution, `0`
    /// returns a reduced-size JPEG (zgrimz/fujifilm-ptp-reference `docs/05-raw-conversion.md#output`).
    @discardableResult
    func cook(raf: Data, filename: String, settings: RecipeSettings,
              progress: String = "", fullResolution: Bool = true,
              recordContext: CookRecordContext? = nil) async -> ConversionResult {
        do throws(CameraBusy) {
            return try await gate.run("develop") {
                await self.cookExclusively(.inMemory(raf, filename: filename), settings: settings,
                                          progress: progress, fullResolution: fullResolution,
                                          recordContext: recordContext)
            }
        } catch {
            return .refusedBecauseBusy(sourceFilename: filename)
        }
    }

    private static func unstartedCook(filename: String) -> ConversionResult {
        var result = ConversionResult(sourceFilename: filename, success: false, clampedFields: [],
            errorMessage: "This develop wasn't started because the previous conversion's outcome is uncertain. Reconnect the camera before trying again.")
        result.evidence.failureReason = "previous_conversion_uncertain"
        return result
    }

    private func cookExclusively(_ source: RAFSource, settings: RecipeSettings,
                                progress: String = "", fullResolution: Bool = true,
                                recordContext: CookRecordContext? = nil) async -> ConversionResult {
        // Wrapped rather than instrumented in place: `performCook` returns from four points, and one
        // logging site that every path funnels through can't drift out of step with them the way
        // four could. The compatibility record is written from here for the same reason.
        let startedAt = CameraCompatibilityReport.timestamp()
        let sessionEpoch = session.epoch.current
        reports.isTracing = true
        let result = await performCook(source, settings: settings,
                                       progress: progress, fullResolution: fullResolution)
        if session.operationIsCurrent(sessionEpoch) { reports.isTracing = false }
        // Every cook, not only the anomalies the log line below covers. A clean develop on a body
        // nobody here owns is evidence — it is most of the evidence, in fact, since nearly every body
        // enabled for conversion is enabled by inference. The exceptions are the X-T50, driven end to
        // end here, and the GFX100S, enabled on its owner's harvested profile and develop.
        if session.operationIsCurrent(sessionEpoch) {
            recordCook(result, at: startedAt, filmSimulation: settings.filmSimulation?.displayName, context: recordContext)
        }
        // Anomalies only — a clean success is routine and the failure paths inside `performCook`
        // already log themselves. What would otherwise leave no trace is a develop that *succeeded*
        // but clamped fields or never had its profile confirmed — the JPEG may not reflect the
        // recipe, which is exactly what a shared problem report needs to show.
        if result.success && result.isReportableAnomaly {
            AppLog.info(.kitchen, "Develop succeeded with anomalies on \(session.connected?.model?.id ?? "unrecognized") — profile verification: \(result.evidence.profileVerification ?? "unavailable"), clamped fields: \(result.clampedFields.count)")
        }
        return result
    }

    private func performCook(_ source: RAFSource, settings: RecipeSettings,
                             progress: String, fullResolution: Bool) async -> ConversionResult {
        let sessionEpoch = session.epoch.current
        let filename = source.filename
        guard session.canConvert, let model = session.connected?.model, model.supportsRawConversion,
              let conv = session.rawConversionTransport else {
            var result = ConversionResult(sourceFilename: filename, success: false, clampedFields: [],
                                          errorMessage: CameraError.rawConversionUnsupported.errorDescription)
            result.evidence.failureReason = "raw_conversion_unsupported"
            return result
        }
        do {
            let loaded = try await loadRAF(source, using: conv, progress: progress)
            return await develop(loaded, settings: settings, model: model, using: conv,
                                 progress: progress, fullResolution: fullResolution)
        } catch let failure as LoadFailure {
            // Reason, never `filename` — a RAF's name is the user's and stays out of the log.
            AppLog.error(.kitchen, "Cook failed while loading — \(failure.reason)")
            if session.operationIsCurrent(sessionEpoch) { session.setStatus(.connected) }
            var result = ConversionResult(sourceFilename: filename, success: false,
                                          clampedFields: [], errorMessage: failure.message)
            result.diagnostics = failure.diagnostics
            result.evidence = failure.evidence
            result.evidence.failureReason = failure.evidence.failureReason ?? failure.reason
            result.requiresReconnect = failure.requiresReconnect
            return result
        } catch {
            AppLog.error(.kitchen, "Cook failed — \(error.diagnosticReason)", error)
            if session.operationIsCurrent(sessionEpoch) { session.setStatus(.connected) }
            var result = ConversionResult(sourceFilename: filename, success: false, clampedFields: [],
                                          errorMessage: (error as? CameraError)?.errorDescription ?? error.localizedDescription)
            result.evidence.failureReason = error.diagnosticReason
            return result
        }
    }

    /// Convert several RAFs, each with its own recipe, reporting determinate progress (like
    /// `pushBatch`). After a file whose outcome leaves the camera's state uncertain, the rest of the
    /// batch is reported as not started.
    @discardableResult
    func cookBatch(_ items: [CookItem],
                   recordContext: CookRecordContext? = nil) async -> [ConversionResult] {
        do throws(CameraBusy) {
            return try await gate.run("develop batch") {
                await self.cookBatchExclusively(items, recordContext: recordContext)
            }
        } catch {
            return items.map { .refusedBecauseBusy(sourceFilename: $0.raf.filename) }
        }
    }

    private func cookBatchExclusively(_ items: [CookItem],
                                      recordContext: CookRecordContext?) async -> [ConversionResult] {
        var results: [ConversionResult] = []
        var interrupted = false
        let sessionEpoch = session.epoch.current
        let total = items.count
        conversionProgress = BatchProgress(completed: 0, total: total)
        for (i, item) in items.enumerated() {
            interrupted = interrupted || !session.operationIsCurrent(sessionEpoch)
            let prefix = total > 1 ? "(\(i + 1) of \(total)) " : ""
            let result = interrupted ? Self.unstartedCook(filename: item.raf.filename)
                : await cookExclusively(item.raf, settings: item.settings, progress: prefix,
                                      recordContext: recordContext)
            results.append(result)
            interrupted = interrupted || result.requiresReconnect
                || (!result.success && result.evidence.cleanupOutcome == "retained")
            if session.operationIsCurrent(sessionEpoch) {
                conversionProgress = BatchProgress(completed: i + 1, total: total)
            }
        }
        if session.operationIsCurrent(sessionEpoch) { conversionProgress = nil }
        return results
    }

    /// Develop each RAF with each recipe (a grid of up to 3×3) for the **Test Kitchen**, returning
    /// the results grouped per source file so the UI can show each photo's versions side by side.
    /// Photo-major: each RAF is uploaded to the camera **once**, then re-developed for every recipe
    /// against that single upload, with determinate progress across the whole grid.
    ///
    /// `displayName` is what the resulting version is labeled with. The conversion profile carries no
    /// name, so none is written.
    @discardableResult
    func cookMatrix(rafs: [RAFSource],
                    recipes: [(settings: RecipeSettings, displayName: String, filmSimulation: String?)],
                    recordContexts: [CookRecordContext] = []) async -> [TestKitchenComparison] {
        do throws(CameraBusy) {
            return try await gate.run("develop comparison") {
                await self.cookMatrixExclusively(rafs: rafs, recipes: recipes, recordContexts: recordContexts)
            }
        } catch {
            return rafs.map { raf in
                TestKitchenComparison(sourceFilename: raf.filename, versions: recipes.map {
                    TestKitchenVersion(recipeName: $0.displayName, filmSimulation: $0.filmSimulation,
                                       result: .refusedBecauseBusy(sourceFilename: raf.filename))
                })
            }
        }
    }

    private func cookMatrixExclusively(rafs: [RAFSource],
        recipes: [(settings: RecipeSettings, displayName: String, filmSimulation: String?)],
        recordContexts: [CookRecordContext]) async -> [TestKitchenComparison] {
        let sessionEpoch = session.epoch.current
        let total = rafs.count * recipes.count
        guard total > 0 else { return [] }
        guard session.canConvert, let model = session.connected?.model, model.supportsRawConversion,
              let conv = session.rawConversionTransport else {
            return rafs.map { raf in
                TestKitchenComparison(sourceFilename: raf.filename,
                                      versions: recipes.enumerated().map { recipeIndex, recipe in
                    var result = ConversionResult(sourceFilename: raf.filename, success: false,
                                                  clampedFields: [],
                                                  errorMessage: CameraError.rawConversionUnsupported.errorDescription)
                    result.evidence.failureReason = "raw_conversion_unsupported"
                    if recordContexts.indices.contains(recipeIndex) {
                        recordCook(result, at: CameraCompatibilityReport.timestamp(), filmSimulation: recipe.filmSimulation,
                                   context: recordContexts[recipeIndex])
                    }
                    return TestKitchenVersion(recipeName: recipe.displayName,
                                              filmSimulation: recipe.filmSimulation, result: result)
                })
            }
        }

        conversionProgress = BatchProgress(completed: 0, total: total)
        var comparisons: [TestKitchenComparison] = []
        var completed = 0
        var interrupted = false
        // Armed once for the whole grid rather than per cell: a matrix is one operation from the
        // camera's point of view, and the trace is bounded anyway.
        reports.isTracing = true
        defer { if session.operationIsCurrent(sessionEpoch) { reports.isTracing = false } }

        for raf in rafs {
            interrupted = interrupted || !session.operationIsCurrent(sessionEpoch)
            var versions: [TestKitchenVersion] = []
            func prefix() -> String { total > 1 ? "(\(completed + 1) of \(total)) " : "" }
            if interrupted {
                comparisons.append(TestKitchenComparison(sourceFilename: raf.filename, versions: recipes.map {
                    TestKitchenVersion(recipeName: $0.displayName, filmSimulation: $0.filmSimulation,
                                       result: Self.unstartedCook(filename: raf.filename))
                }))
                completed += recipes.count
                if session.operationIsCurrent(sessionEpoch) {
                    conversionProgress = BatchProgress(completed: completed, total: total)
                }
                continue
            }
            do {
                // One upload per photo — every recipe below re-triggers against this same buffer.
                let loaded = try await loadRAF(raf, using: conv, progress: prefix())
                for (recipeIndex, recipe) in recipes.enumerated() {
                    interrupted = interrupted || !session.operationIsCurrent(sessionEpoch)
                    // Downscaled trigger: grid cells are comparison previews, and up to 9 full-res
                    // develops would be needlessly slow. Users re-cook the winner at full resolution.
                    let startedAt = CameraCompatibilityReport.timestamp()
                    let result = interrupted ? Self.unstartedCook(filename: raf.filename)
                        : await develop(loaded, settings: recipe.settings, model: model,
                                        using: conv, progress: prefix(), fullResolution: false)
                    interrupted = interrupted || result.requiresReconnect
                        || (!result.success && result.evidence.cleanupOutcome == "retained")
                    // Recorded here because the grid calls `develop` directly, not through
                    // `cookExclusively`, which records every other develop.
                    if session.operationIsCurrent(sessionEpoch) {
                        recordCook(result, at: startedAt, filmSimulation: recipe.filmSimulation,
                                   context: recordContexts.indices.contains(recipeIndex) ? recordContexts[recipeIndex] : nil)
                    }
                    versions.append(TestKitchenVersion(recipeName: recipe.displayName,
                                                       filmSimulation: recipe.filmSimulation, result: result))
                    completed += 1
                    if session.operationIsCurrent(sessionEpoch) {
                        conversionProgress = BatchProgress(completed: completed, total: total)
                    }
                }
            } catch let failure as LoadFailure {
                interrupted = interrupted || failure.requiresReconnect
                AppLog.error(.kitchen, "Test Kitchen: photo failed to load — \(failure.reason), \(recipes.count) cell(s) blanked")
                // Without record contexts, one record for the row rather than one per cell: the load
                // failed once, and identical cell records would crowd the cap without adding a fact.
                // With contexts, each cell is recorded below against its own. A blanked row on an
                // unfamiliar body is usually an unresolved D185 layout, and the profile length rides
                // along in the evidence.
                var rowResult = ConversionResult(sourceFilename: raf.filename, success: false,
                                                 clampedFields: [], errorMessage: nil)
                rowResult.evidence = failure.evidence
                rowResult.evidence.failureReason = failure.evidence.failureReason ?? failure.reason
                rowResult.requiresReconnect = failure.requiresReconnect
                if recordContexts.isEmpty && session.operationIsCurrent(sessionEpoch) {
                    recordCook(rowResult, at: CameraCompatibilityReport.timestamp(), filmSimulation: nil)
                }
                // The photo didn't load, so none of its versions can be developed. Each cell reports
                // the reason rather than the row being dropped silently.
                for (recipeIndex, recipe) in recipes.enumerated() {
                    var result = ConversionResult(sourceFilename: raf.filename, success: false,
                                                  clampedFields: [], errorMessage: failure.message)
                    result.diagnostics = failure.diagnostics
                    result.evidence = rowResult.evidence
                    result.requiresReconnect = failure.requiresReconnect
                    if recordContexts.indices.contains(recipeIndex), session.operationIsCurrent(sessionEpoch) {
                        recordCook(result, at: CameraCompatibilityReport.timestamp(), filmSimulation: recipe.filmSimulation,
                                   context: recordContexts[recipeIndex])
                    }
                    versions.append(TestKitchenVersion(recipeName: recipe.displayName,
                                                       filmSimulation: recipe.filmSimulation, result: result))
                    completed += 1
                    if session.operationIsCurrent(sessionEpoch) {
                        conversionProgress = BatchProgress(completed: completed, total: total)
                    }
                }
                if session.operationIsCurrent(sessionEpoch) { session.setStatus(.connected) }
            } catch {
                AppLog.error(.kitchen, "Test Kitchen: row abandoned — \(error.diagnosticReason)", error)
                // A failed load still has one outcome per planned cell. Keeping the row's shape
                // lets the guided test distinguish a failed comparison from an omitted recipe.
                for (recipeIndex, recipe) in recipes.enumerated() {
                    var result = ConversionResult(sourceFilename: raf.filename, success: false,
                                                  clampedFields: [],
                                                  errorMessage: (error as? CameraError)?.errorDescription ?? error.localizedDescription)
                    result.evidence.failureReason = error.diagnosticReason
                    if session.operationIsCurrent(sessionEpoch) {
                        recordCook(result, at: CameraCompatibilityReport.timestamp(), filmSimulation: recipe.filmSimulation,
                                   context: recordContexts.indices.contains(recipeIndex) ? recordContexts[recipeIndex] : nil)
                    }
                    versions.append(TestKitchenVersion(recipeName: recipe.displayName,
                                                       filmSimulation: recipe.filmSimulation, result: result))
                    completed += 1
                    if session.operationIsCurrent(sessionEpoch) {
                        conversionProgress = BatchProgress(completed: completed, total: total)
                    }
                }
                if session.operationIsCurrent(sessionEpoch) { session.setStatus(.connected) }
            }
            comparisons.append(TestKitchenComparison(sourceFilename: raf.filename, versions: versions))
        }

        if session.operationIsCurrent(sessionEpoch) { conversionProgress = nil }
        return comparisons
    }

    // MARK: - The two halves

    /// Upload one RAF into the camera's conversion buffer and read back the profile it produces.
    private func loadRAF(_ source: RAFSource, using conv: RawConversionTransport,
                         progress: String) async throws -> LoadedRAF {
        let sessionEpoch = session.epoch.current
        let filename = source.filename
        let origin = try await upload(source, using: conv, progress: progress)
        guard session.operationIsCurrent(sessionEpoch) else { throw CameraError.disconnectedDuringOperation }

        // The profile's length varies by body but the parameter table's base doesn't
        // (zgrimz/fujifilm-ptp-reference `docs/06-conversion-profile.md#layout`). `resolveLayout`
        // validates the base by decoding it: a one-cell misalignment scrambles Dynamic Range and film
        // simulation together, which is what it checks for. If nothing decodes plausibly, the load
        // aborts before anything is written rather than shift every field write by a cell.
        session.setStatus(.working("\(progress)Reading profile…"))
        let profile: Data?
        do {
            profile = try await conv.readProperty(FujiPTP.Prop.rawConvProfile)
        } catch CameraError.ptpError(code: 0x2002) where origin != .sameBody {
            AppLog.error(.kitchen, "The camera took the upload and refused the D185 read (PTP 0x2002) — a RAF from another body is a published cause")
            throw LoadFailure(message: CameraError.rafFromDifferentBody(filename: filename).message,
                              diagnostics: nil, reason: "raf_from_different_body")
        } catch {
            AppLog.error(.kitchen, "Reading the D185 conversion profile failed — \(error.diagnosticReason)", error)
            throw LoadFailure(message: (error as? CameraError)?.errorDescription ?? error.localizedDescription,
                              diagnostics: nil, reason: error.diagnosticReason)
        }
        guard let base = profile, !base.isEmpty else {
            AppLog.error(.kitchen, "The camera answered the D185 read with no data")
            throw LoadFailure(message: "The camera returned no conversion profile, so no recipe was applied.",
                              diagnostics: nil, reason: "profile_empty")
        }
        guard session.operationIsCurrent(sessionEpoch) else { throw CameraError.disconnectedDuringOperation }
        // From here the profile exists, so its shape is reportable whichever way the layout goes —
        // and it is *most* worth reporting on the body where the layout doesn't resolve.
        var evidence = CookEvidence()
        evidence.profileLength = base.count
        evidence.declaredParams = FujiRawConvProfile.numParams(in: base)
        guard let layout = FujiRawConvProfile.resolveLayout(base) else {
            let diagnostic = FujiRawConvProfile.layoutDiagnostic(base)
            AppLog.error(.kitchen, "D185 layout unresolved for \(session.connected?.model?.id ?? "unrecognized") — \(base.count) byte profile")
            evidence.failureReason = "conversion_profile_mismatch"
            throw LoadFailure(
                message: CameraError.conversionProfileMismatch(detail: diagnostic).message,
                diagnostics: "D185 layout not resolved\n" + diagnostic
                    + "\n\nfirst 64 bytes:\n" + FujiRawConvProfile.hexDump(base),
                reason: "conversion_profile_mismatch",
                evidence: evidence)
        }
        evidence.layoutBase = layout.base
        return LoadedRAF(filename: filename, base: base, layout: layout, sessionEpoch: sessionEpoch, evidence: evidence)
    }

    /// Send the RAF's bytes. They are asked for here and go out of scope with this call: the profile
    /// read and every develop after it work on the camera's buffer, not the file.
    ///
    /// A file without the RAF signature is refused before anything is sent. The Files picker admits
    /// Fujifilm RAWs, but a file's type comes from its name, not its bytes; the camera needn't refuse
    /// an upload it can't convert: an X-M5 answered OK to an
    /// upload it most likely couldn't convert and `0x2002` only to the profile read that followed
    /// (zgrimz/fujifilm-ptp-reference `docs/05-raw-conversion.md#prerequisites`).
    ///
    /// A body develops only RAFs it shot (same section), and the file's header names the body that
    /// shot it (`RAFHeader`), so a file from another body is refused here too. A `0x2002` (General
    /// Error) from the upload itself names no cause and is reported as a refusal: the published
    /// foreign-RAF failure is at the profile read after the upload (same section), which is where
    /// `loadRAF` names it. Returns the header's verdict for that read.
    private func upload(_ source: RAFSource, using conv: RawConversionTransport,
                        progress: String) async throws -> RAFHeader.Origin {
        let filename = source.filename
        let raf: Data
        do {
            raf = try await source.load()
        } catch {
            // Domain and code only: a `CocoaError` description names the file.
            AppLog.error(.kitchen, "Couldn't read the RAF to upload — \(AppLog.bounded(error))")
            throw CameraError.rafUnreadable
        }
        let kind = FileKind.detect(raf)
        guard kind == .raf else {
            AppLog.error(.kitchen, "Refused to upload a file with no RAF header (\(kind.rawValue))")
            let refusal = CameraError.notARAF(filename: filename, kind: kind)
            throw LoadFailure(message: refusal.message, diagnostics: nil, reason: refusal.diagnosticReason)
        }
        let body = session.connected?.model
        let origin = body.flatMap { body in RAFHeader(raf)?.origin(for: body) } ?? .undetermined
        if case .otherBody(let shotOn) = origin, let body {
            AppLog.error(.kitchen, "Refused to upload a RAF whose header names another body (\(shotOn.id); connected \(body.id))")
            throw LoadFailure(message: CameraError.rafShotOnAnotherBody(filename: filename, shotOn: shotOn.id,
                                                                        connected: body.id).message,
                              diagnostics: nil, reason: "raf_from_different_body")
        }
        // Said either way, so a report can tell a check that passed from one that had nothing to
        // check.
        AppLog.info(.kitchen, origin == .sameBody
            ? "RAF header names the connected body (\(body?.id ?? "unrecognized")); uploading"
            : "RAF header gives no body to check against; the camera decides")
        session.setStatus(.working("\(progress)Sending \(filename)…"))
        do {
            try await conv.sendObject(raf, filename: filename)
        } catch CameraError.ptpError(code: 0x2002) {
            let refusal = origin == .sameBody ? CameraError.uploadRefused(filename: filename)
                                              : CameraError.uploadRefusedWithoutCause(filename: filename)
            AppLog.error(.kitchen, origin == .sameBody
                ? "Camera refused the upload (PTP 0x2002) of a RAF whose header names this body"
                : "Camera refused the upload (PTP 0x2002) of a RAF whose header names no body to check")
            throw LoadFailure(message: refusal.message, diagnostics: nil, reason: refusal.diagnosticReason)
        } catch {
            AppLog.error(.kitchen, "sendObject failed — \(error.diagnosticReason)", error)
            let unknown = Self.commandCompletionIsUnknown(error)
            let message = (error as? CameraError)?.errorDescription ?? error.localizedDescription
            throw LoadFailure(message: message + (unknown ? " The upload's completion is unconfirmed; reconnect before another develop." : ""),
                              diagnostics: unknown ? "The upload's completion is unconfirmed. No further camera changes were sent; reconnect before another develop." : nil,
                              reason: error.diagnosticReason, requiresReconnect: unknown)
        }
        return origin
    }

    /// Apply one recipe to an already-uploaded RAF and retrieve the JPEG the camera produces.
    /// Safe to call repeatedly for the same `LoadedRAF` — that's the point of the split.
    private func develop(_ loaded: LoadedRAF, settings: RecipeSettings, model: CameraModel,
                         using conv: RawConversionTransport,
                         progress: String, fullResolution: Bool) async -> ConversionResult {
        var result = ConversionResult(sourceFilename: loaded.filename, success: false,
                                      clampedFields: [], errorMessage: nil)
        result.evidence = loaded.evidence
        result.evidence.fullResolution = fullResolution
        var triggerAttempted = false
        var writePending = false

        // Report what gets clamped and compute the values actually applied. Both toning axes count:
        // the profile has a cell for each.
        let issues = RecipeCompatibility.analyze(settings, for: model)
        result.clampedFields = issues.compactMap {
            switch $0.kind {
            case .valueClamped, .magentaGreenClamped: return $0.subject
            default: return nil
            }
        }
        let clamped = RecipeCompatibility.clamped(settings, to: model)
        if let requested = settings.filmSimulation, clamped.filmSimulation == nil {
            let retained = FujiRawConvProfile.decode(loaded.base, layout: loaded.layout).filmSimulation?.displayName
                ?? "the photo's original film simulation"
            result.warnings.append("\(requested.displayName) isn't available on \(model.displayName). This develop keeps \(retained).")
        }

        do {
            guard session.operationIsCurrent(loaded.sessionEpoch) else { throw CameraError.disconnectedDuringOperation }
            // Say what happened to dynamic range — in every case, not just the one that clamps. DR
            // Auto is the single most common DR setting in the library, and a develop that renders
            // at the frame's own DR without a message leaves a DR400 frame visibly flatter than the
            // recipe's author intended, with nothing on screen connecting the two.
            switch FujiRawConvProfile.resolveDynamicRange(clamped, base: loaded.base, layout: loaded.layout) {
            case .cappedToAsShot(let recipePct, let asShotPct):
                result.evidence.dynamicRange = "cappedToAsShot(\(recipePct)->\(asShotPct))"
                // Both channels, doing different jobs. The bare field name joins the scannable
                // "what changed" line alongside any model-range clamps; the sentence explains it. One
                // entry carrying the whole explanation would render under a hardcoded "Clamped to
                // camera range:" — wrong twice over, since the limit is this photo's exposure
                // headroom and not the camera's range at all.
                result.clampedFields.append("Dynamic Range")
                result.notes.append("Dynamic Range: developed at DR\(asShotPct), not the recipe's DR\(recipePct). This RAW was shot at DR\(asShotPct), so it holds no extra highlight headroom to develop from — forcing DR\(recipePct) onto it renders a heavy green cast instead of a brighter picture.")
            case .autoResolved(let picked, let asShot):
                result.evidence.dynamicRange = "autoResolved(\(picked), asShot \(asShot))"
                // A note, not a clamp: nothing went wrong, and routing it through `clampedFields`
                // would both mislabel it ("Clamped to camera range") and mark every DR-Auto develop
                // as a reportable anomaly.
                let why = picked < asShot
                    ? "The recipe says DR Auto, and the camera's Auto never picks DR\(asShot) — that's a manual setting, which is what this frame was shot at."
                    : "The recipe says DR Auto, which the camera decides as you shoot; this frame was shot at DR\(asShot)."
                result.notes.append("Dynamic Range: developed at DR\(picked). \(why)")
            case .applied:
                result.evidence.dynamicRange = "applied"
            case .untouched:
                result.evidence.dynamicRange = "untouched"
            }

            // D-Range Priority isn't written by a develop: `patch` never touches cell 7, whose
            // encoding is unknown (zgrimz/fujifilm-ptp-reference
            // `docs/06-conversion-profile.md#d-range-priority-cell-7--unknown`). Say so when the recipe
            // asks for one; that much is certain from the code, whatever cell 7 turns out to mean.
            //
            // The converse, a frame shot with D-Range Priority on, is deliberately not reported. On
            // the bank protocol the priority locks out Highlight and Shadow Tone
            // (`docs/04-custom-slots.md#the-d-range-priority-interlock`), and a develop may keep the
            // frame's setting and render the same way, but nobody has measured that. Detecting it
            // means reading cell 7 and deciding some value means "on": a guess about an unknown
            // encoding, in a sentence telling the user how their photo was rendered. Wrong is worse
            // than silent. `FujiRawConvProfile.rawCell` exposes the cell so a probe that settles it
            // has something to read.
            if let recipeDRP = clamped.dRangePriority, recipeDRP != .off, model.supports(.dRangePriority) {
                result.notes.append("D-Range Priority: a develop can't switch it on, so this shot's own setting was kept. The recipe asks for \(recipeDRP.displayName).")
            }

            // Patched onto the photo's own profile, never rebuilt, so cells the app doesn't edit keep
            // the camera's values.
            session.setStatus(.working("\(progress)Applying recipe…"))
            let plan = FujiRawConvProfile.patchPlan(base: loaded.base, with: clamped,
                                                    model: model, layout: loaded.layout)
            let patched = plan.profile
            result.diagnostics = FujiRawConvProfile.fieldReport(base: loaded.base, patched: patched,
                                                                settings: clamped, layout: loaded.layout)
            let wire = FujiRawConvProfile.hostWriteForm(patched)
            writePending = true
            try await conv.writeProperty(FujiPTP.Prop.rawConvProfile, wire)
            writePending = false

            // Confirm the camera took the profile before triggering. An OK to `SetDevicePropValue`
            // doesn't say what the camera stored (zgrimz/fujifilm-ptp-reference
            // `docs/05-raw-conversion.md#verify-the-profile-before-triggering`), and a conversion run
            // against a stale profile renders a valid JPEG of the wrong thing, indistinguishable from
            // a recipe that just looks bad. Same discipline as the slot push. One retry, because the
            // failure this is aimed at is intermittent; then the develop proceeds and says so, rather
            // than refusing over a mismatch that may be a normalisation nobody has characterised.
            var verification = await verifyProfile(conv, loaded: loaded, expected: patched, fields: plan.fields)
            if verification.state == "mismatched" {
                guard session.operationIsCurrent(loaded.sessionEpoch) else { throw CameraError.disconnectedDuringOperation }
                writePending = true
                try await conv.writeProperty(FujiPTP.Prop.rawConvProfile, wire)
                writePending = false
                verification = await verifyProfile(conv, loaded: loaded, expected: patched, fields: plan.fields)
            }
            result.evidence.profileVerified = verification.matched
            result.evidence.profileVerification = verification.state
            result.evidence.mismatches = verification.mismatches
            if verification.state == "mismatched" || verification.state == "unavailable" {
                result.warnings.append(verification.state == "unavailable"
                    ? "The recipe profile couldn't be read back, so this version's settings are unverified."
                    : "The camera didn't confirm the recipe profile, so this version may not match the recipe.")
                result.diagnostics = (["profile verification: \(verification.state)"]
                                      + verification.mismatches.map { "  " + $0 } + [""]).joined(separator: "\n")
                    + (result.diagnostics ?? "")
            }

            // Snapshot existing handles so we can detect the new JPEG after conversion. A failed
            // snapshot aborts the develop: with an empty set every object on the card looks new, and
            // the first one seen would be fetched as the JPEG and then deleted.
            let before = Set(try await conv.getObjectHandles())
            guard session.operationIsCurrent(loaded.sessionEpoch) else { throw CameraError.disconnectedDuringOperation }

            // `0xD183`: 1 = full resolution, 0 = reduced size; 2 is refused with `0x201C`
            // (zgrimz/fujifilm-ptp-reference `docs/05-raw-conversion.md#the-sequence`).
            session.setStatus(.working("\(progress)Converting…"))
            triggerAttempted = true
            writePending = true
            try await conv.writeProperty(FujiPTP.Prop.startRawConversion,
                                         FujiEncoding.packU16(fullResolution ? 1 : 0))
            writePending = false

            let handle = try await waitForConvertedObject(conv, excluding: before, sessionEpoch: loaded.sessionEpoch)

            session.setStatus(.working("\(progress)Retrieving JPEG…"))
            _ = try await retrieveConversionOutput(conv, handle: handle, sessionEpoch: loaded.sessionEpoch,
                                                   result: &result)
            if session.operationIsCurrent(loaded.sessionEpoch) { session.setStatus(.connected) }
        } catch {
            AppLog.error(.kitchen, "Develop failed — \(error.diagnosticReason)", error)
            result.errorMessage = (error as? CameraError)?.errorDescription ?? error.localizedDescription
            result.evidence.failureReason = (error as? DevelopOutputError)?.diagnosticReason ?? error.diagnosticReason
            if writePending && Self.commandCompletionIsUnknown(error) {
                result.requiresReconnect = true
                result.errorMessage = (result.errorMessage ?? "The camera command failed.")
                    + " Its completion is unconfirmed; reconnect before another develop."
                result.warnings.append("A camera command's completion is unconfirmed. No further camera changes were sent; reconnect before another develop.")
            }
            if triggerAttempted {
                result.evidence.cleanupOutcome = "retained"
                switch error as? DevelopOutputError {
                case .unexpectedFormat, .incompleteDownload, .invalidJPEG:
                    result.evidence.outputValidation = "invalid"
                case .recoverySaveFailed:
                    result.evidence.outputValidation = "validated"
                default:
                    result.evidence.outputValidation = "unavailable"
                }
            }
            if session.operationIsCurrent(loaded.sessionEpoch) { session.setStatus(.connected) }
        }
        return result
    }

    /// Download the converted object, validate it, put it on disk at `result.recoveryFileURL`, and
    /// remove the camera's copy. Marks `result` a success once the file is there. Returns the bytes
    /// for the one caller that reads them straight away, the probe's MakerNote check; a develop
    /// lets them go, since the file is the handover to the store.
    private func retrieveConversionOutput(_ conv: RawConversionTransport, handle: UInt32,
                                          sessionEpoch: UInt64, result: inout ConversionResult) async throws -> Data {
        guard session.operationIsCurrent(sessionEpoch) else { throw CameraError.disconnectedDuringOperation }
        let info = try await conv.getObjectInfo(handle)
        guard info.objectFormat == 0x3801 else { throw DevelopOutputError.unexpectedFormat }
        guard session.operationIsCurrent(sessionEpoch) else { throw CameraError.disconnectedDuringOperation }
        let jpeg = try await conv.getObject(handle)
        result.evidence.outputBytes = jpeg.count
        let outputID = result.id
        let expectedSize = info.compressedSize
        let recoveryDirectory = DevelopOutputRecovery.destinationDirectory
        let saved = try await Task.detached(priority: .userInitiated) {
            try DevelopOutputRecovery.validate(jpeg, expectedSize: expectedSize)
            return try DevelopOutputRecovery.save(jpeg, id: outputID, directory: recoveryDirectory)
        }.value
        result.recoveryFileURL = saved
        result.evidence.outputValidation = "validated"
        // The local copy survives a later library save failure. A reconnect never authorizes
        // deletion using a handle from the previous session.
        if session.operationIsCurrent(sessionEpoch) {
            do {
                try await conv.deleteObject(handle)
                result.evidence.cleanupOutcome = "deleted"
            } catch {
                if Self.commandCompletionIsUnknown(error) {
                    result.evidence.cleanupOutcome = "unknown"
                    result.requiresReconnect = true
                    result.warnings.append("The JPEG was saved, but camera cleanup couldn't be confirmed. Reconnect before another develop.")
                } else {
                    result.evidence.cleanupOutcome = "failed"
                    result.warnings.append("The JPEG was saved, but its temporary camera copy couldn't be removed.")
                }
            }
        } else {
            result.evidence.cleanupOutcome = "retained"
            result.warnings.append("The JPEG was saved, but the camera connection changed before cleanup. Its camera copy was left alone.")
        }
        result.evidence.outputBytes = jpeg.count
        result.success = true
        return jpeg
    }

    /// A valid PTP refusal is a completed command. A missing/malformed response or transport
    /// failure cannot establish whether a submitted mutation landed, so later mutations stop.
    private static func commandCompletionIsUnknown(_ error: Error) -> Bool {
        if case CameraError.ptpError = error { return false }
        return true
    }

    private struct ProfileVerification {
        let state: String
        var mismatches: [String] = []
        var matched: Bool? {
            switch state {
            case "matched": return true
            case "mismatched": return false
            default: return nil
            }
        }
    }

    private func verifyProfile(_ conv: RawConversionTransport, loaded: LoadedRAF,
                               expected: Data, fields: Set<FujiRawConvProfile.Field>) async -> ProfileVerification {
        guard !fields.isEmpty else { return ProfileVerification(state: "not_tested") }
        guard let readBack = try? await conv.readProperty(FujiPTP.Prop.rawConvProfile),
              !readBack.isEmpty else { return ProfileVerification(state: "unavailable") }
        guard FujiRawConvProfile.resolveLayout(readBack)?.base == loaded.layout.base,
              let expectedIOP = FujiRawConvProfile.iopCode(in: loaded.base),
              FujiRawConvProfile.iopCode(in: readBack) == expectedIOP,
              let count = FujiRawConvProfile.numParams(in: readBack),
              let stringLength = readBack.readLE(UInt8.self, at: 2),
              [expectedIOP.utf16.count, expectedIOP.utf16.count + 1].contains(Int(stringLength)),
              (readBack.count - loaded.layout.base) % FujiRawConvProfile.fieldSize == 0 else {
            return ProfileVerification(state: "unavailable")
        }
        let cells = (readBack.count - loaded.layout.base) / FujiRawConvProfile.fieldSize
        // A first camera read counts its cells; a read after a host write can count one fewer or
        // echo the host's 29 even on a shorter profile (zgrimz/fujifilm-ptp-reference
        // `docs/06-conversion-profile.md#numparams-means-different-things-in-each-direction`). Any
        // other count isn't valid evidence.
        guard count == cells || count == cells - 1 || (count == 29 && cells <= 30) else {
            return ProfileVerification(state: "unavailable")
        }
        guard fields.allSatisfy({ FujiRawConvProfile.offset(of: $0, in: readBack, layout: loaded.layout) != nil }) else {
            return ProfileVerification(state: "unavailable")
        }
        let mismatches = FujiRawConvProfile.verificationMismatches(expected: expected, actual: readBack,
                                                                  fields: fields, layout: loaded.layout)
        return ProfileVerification(state: mismatches.isEmpty ? "matched" : "mismatched", mismatches: mismatches)
    }

    /// Poll `getObjectHandles` until a handle appears that wasn't present before the trigger.
    private func waitForConvertedObject(_ conv: RawConversionTransport,
                                        excluding before: Set<UInt32>, sessionEpoch: UInt64) async throws -> UInt32 {
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 500_000_000)
            guard session.operationIsCurrent(sessionEpoch) else { throw CameraError.disconnectedDuringOperation }
            let now = try await conv.getObjectHandles()
            guard session.operationIsCurrent(sessionEpoch) else { throw CameraError.disconnectedDuringOperation }
            let candidates = Set(now).subtracting(before)
            guard candidates.count <= 1 else { throw DevelopOutputError.ambiguousObjects }
            if let new = candidates.first { return new }
        }
        throw CameraError.conversionTimedOut
    }

    // MARK: - D185 dynamic-range probe

    /// A probe run: the text report, plus the previews it developed along the way.
    struct ConversionProbeRun {
        let report: String
        /// The developed previews, ready for `CookStore.persist`. Nil when nothing developed.
        /// Persisting is the caller's job — `RawConversionService` has no `ModelContext`, and
        /// `DevelopView` already owns that step for an ordinary cook.
        var comparison: TestKitchenComparison?
    }

    /// One candidate written into the conversion profile's Dynamic Range cell, and what came back.
    struct ConversionProbeEntry: Identifiable, Equatable {
        let step: Int
        /// The raw value written into cell 6.
        let wrote: Int
        /// Nil when the profile write was answered OK; else why it failed.
        let writeError: String?
        /// What cell 6 read as after the write — the camera may normalise rather than refuse.
        let readBack: Int?
        /// What the produced JPEG says it was *actually developed at*. The profile read-back only
        /// proves the camera stored the value; this proves it meant something by it.
        let rendered: DynamicRange?
        let renderNote: String?
        var completionUnknown = false

        var id: Int { step }

        var outcome: String {
            if completionUnknown { return "OUTCOME UNKNOWN (\(writeError ?? "no confirmed response"))" }
            if let writeError { return "rejected (\(writeError))" }
            if readBack != wrote { return "OK, cell 6 reads back \(readBack.map(String.init) ?? "—")" }
            return "ACCEPTED"
        }
    }

    /// Does the `0xD185` conversion profile accept the same DR-Auto value `0xD190` does?
    ///
    /// Writes 100, 200, 400 and `FujiEncoding.drAutoSlotValue` into cell 6 one at a time, reading
    /// each back. The three percentages go first as controls: a probe whose controls don't behave
    /// proves nothing about the Auto value. The X-T50 result is on `FujiRawConvProfile.autoCeiling`.
    ///
    /// Each accepted candidate is developed at `0xD183 = 0`, the reduced size X RAW Studio uses for
    /// its previews, and the JPEG's MakerNote is read through `PhotoRecipeReader` to see what the
    /// camera rendered. The original profile is restored at the end, unless a command's outcome or the
    /// session became uncertain; the report then says the restore wasn't attempted. Throws
    /// `CameraBusy`, having sent nothing, when another operation holds the camera.
    func probeConversionDynamicRange(raf: Data, filename: String) async throws(CameraBusy) -> ConversionProbeRun {
        try await gate.run("conversion dynamic range probe") {
            await self.probeConversionDynamicRangeExclusively(raf: raf, filename: filename)
        }
    }

    private func probeConversionDynamicRangeExclusively(raf: Data, filename: String) async -> ConversionProbeRun {
        let sessionEpoch = session.epoch.current
        defer { if session.operationIsCurrent(sessionEpoch) { session.setStatus(.connected) } }
        guard let model = session.connected?.model, model.supportsRawConversion,
              session.connected?.isWritable == true, let conv = session.rawConversionTransport else {
            return ConversionProbeRun(report: "D185 DR probe refused: this camera isn't one the app develops on.")
        }

        let loaded: LoadedRAF
        do {
            loaded = try await loadRAF(.inMemory(raf, filename: filename), using: conv, progress: "Probe: ")
        } catch let failure as LoadFailure {
            return ConversionProbeRun(report: "D185 DR probe: couldn't load the RAF — \(failure.message)")
        } catch {
            return ConversionProbeRun(report: "D185 DR probe: couldn't load the RAF — \(error.diagnosticReason)")
        }

        let asShot = FujiRawConvProfile.rawCell(loaded.base, .dynamicRange, loaded.layout)
        let asShotSim = FujiRawConvProfile.decode(loaded.base, layout: loaded.layout).filmSimulation
        var entries: [ConversionProbeEntry] = []
        // The previews themselves, kept so the look can be judged and not just the EXIF. The probe
        // answers "accepted?" and "labelled as what?"; whether DR400 on a DR200 frame renders the
        // green cast `FujiRawConvProfile.resolveDynamicRange` describes takes looking at the picture.
        var versions: [TestKitchenVersion] = []
        var interrupted = false

        for (step, candidate) in [100, 200, 400, FujiEncoding.drAutoSlotValue].enumerated() {
            guard session.operationIsCurrent(loaded.sessionEpoch) else { interrupted = true; break }
            session.setStatus(.working("Probe: cell 6 = \(candidate)…"))
            var writeError: String?
            let patched = FujiRawConvProfile.probeWriting(base: loaded.base, layout: loaded.layout,
                                                          field: .dynamicRange, rawValue: candidate)
            do {
                try await conv.writeProperty(FujiPTP.Prop.rawConvProfile,
                                             FujiRawConvProfile.hostWriteForm(patched))
            } catch {
                writeError = Self.probeFailureMessage(error)
                interrupted = Self.commandCompletionIsUnknown(error)
            }
            let completionUnknown = interrupted
            var readBack: Int?
            if !completionUnknown {
                readBack = try? await conv.readProperty(FujiPTP.Prop.rawConvProfile)
                    .flatMap { FujiRawConvProfile.rawCell($0, .dynamicRange, loaded.layout) }
            }

            var rendered: DynamicRange?
            var renderNote: String?
            if writeError == nil {
                switch await convertPreviewForProbe(conv, filename: filename, sessionEpoch: loaded.sessionEpoch) {
                case .success(let preview):
                    var kept = preview.result
                    interrupted = kept.requiresReconnect
                    do {
                        rendered = try PhotoRecipeReader.read(preview.jpeg, filename: nil).settings.dynamicRange
                        if rendered == nil { renderNote = "developed, but the JPEG's MakerNote carried no dynamic range" }
                    } catch {
                        renderNote = "developed, but the JPEG's MakerNote couldn't be read (\(error.diagnosticReason))"
                    }
                    kept.evidence.profileVerified = readBack.map { $0 == candidate }
                    kept.evidence.profileVerification = readBack == nil ? "unavailable"
                        : readBack == candidate ? "matched" : "mismatched"
                    if readBack != candidate {
                        kept.warnings.append("The probe's profile value wasn't confirmed before rendering.")
                    }
                    kept.notes = ["Probe: cell 6 ← \(candidate); the camera developed it as "
                                  + (rendered?.displayName ?? "an unreported dynamic range")
                                  + ". The RAF was shot at DR\(asShot.map(String.init) ?? "?")."]
                    versions.append(TestKitchenVersion(recipeName: "cell 6 = \(candidate)",
                                                       filmSimulation: asShotSim?.displayName,
                                                       result: kept))
                case .failure(let error):
                    renderNote = "develop failed — \(Self.probeFailureMessage(error))"
                    interrupted = true
                }
            }
            entries.append(ConversionProbeEntry(step: step, wrote: candidate, writeError: writeError,
                                                readBack: readBack, rendered: rendered,
                                                renderNote: renderNote, completionUnknown: completionUnknown))
            if interrupted { break }
        }

        // Restore while the conversion and original session are still known. An uncertain trigger
        // may still be rendering, so don't send another profile or pretend restoration succeeded.
        var restoreNote = "profile restored"
        if interrupted || !session.operationIsCurrent(loaded.sessionEpoch) {
            restoreNote = "RESTORE NOT ATTEMPTED — a command outcome or the session is uncertain. No further camera changes were sent; reconnect before another develop."
        } else {
            do {
                try await conv.writeProperty(FujiPTP.Prop.rawConvProfile,
                                             FujiRawConvProfile.hostWriteForm(loaded.base))
                let after = try? await conv.readProperty(FujiPTP.Prop.rawConvProfile)
                    .flatMap { FujiRawConvProfile.rawCell($0, .dynamicRange, loaded.layout) }
                if after == nil {
                    restoreNote = "RESTORE UNVERIFIED — the restored profile couldn't be read back."
                } else if after != asShot {
                    restoreNote = "RESTORE MISMATCH — cell 6 is \(after.map(String.init) ?? "—"), was \(asShot.map(String.init) ?? "—")"
                }
            } catch {
                restoreNote = "RESTORE FAILED — \(Self.probeFailureMessage(error)); the profile's final value is unconfirmed."
            }
        }
        if session.operationIsCurrent(loaded.sessionEpoch) { session.setStatus(.connected) }

        var lines = ["D185 Dynamic Range probe — \(model.displayName) fw \(session.connected?.firmwareVersion ?? "?")",
                     "RAF shot at DR\(asShot.map(String.init) ?? "?") · Auto sentinel candidate is \(FujiEncoding.drAutoSlotValue)",
                     ""]
        for entry in entries {
            lines.append("cell 6 ← \(entry.wrote)  \(entry.outcome)")
            if let rendered = entry.rendered { lines.append("    rendered as \(rendered.displayName)") }
            if let note = entry.renderNote { lines.append("    \(note)") }
        }
        lines.append("")
        lines.append(restoreNote)
        if !versions.isEmpty {
            lines.append("\(versions.count) previews saved to Recent Results — open them together to compare.")
        }

        let summary = entries.map { "\($0.wrote)→\($0.outcome)" }.joined(separator: ", ")
        AppLog.info(.kitchen, "D185 DR probe on \(model.id): \(summary) · \(restoreNote)")
        if session.operationIsCurrent(loaded.sessionEpoch) {
            noteInCompatibilityReport("D185 dynamic-range probe: \(summary); \(restoreNote)")
        }

        let report = lines.joined(separator: "\n")
        // Every version carries the whole report, so a probe run opened days later explains itself
        // rather than being four unlabelled renders of the same frame.
        let documented = versions.map { version -> TestKitchenVersion in
            var result = version.result
            result.diagnostics = report
            return TestKitchenVersion(recipeName: version.recipeName,
                                      filmSimulation: version.filmSimulation, result: result)
        }
        return ConversionProbeRun(
            report: report,
            comparison: documented.isEmpty ? nil
                : TestKitchenComparison(sourceFilename: filename, versions: documented))
    }

    // MARK: - Profile harvest

    struct ProfileHarvestOutcome {
        let record: CameraCompatibilityReport.ProfileHarvestRecord
        /// One line, for the log and the step's result card.
        let summary: String
        var layoutResolved: Bool { record.layoutBase != nil }
    }

    /// Whether the profile harvest may run: a trusted identification and a transport that can
    /// upload. Deliberately **not** `canConvert`: the harvest gathers the evidence that
    /// `supportsRawConversion` is decided on, so requiring it would keep that evidence out of reach.
    var canHarvestProfile: Bool {
        guard let connected = session.connected, connected.identification.isTrusted else { return false }
        return session.rawConversionTransport != nil
    }

    /// Upload one RAF the camera shot, read the conversion profile it produces, and stop.
    ///
    /// The first half of a develop — what `loadRAF` does — with nothing after it: no profile
    /// patch, no `0xD183`, no JPEG. That half is the only thing that can settle whether a body
    /// converts, because `0xD185` holds a profile only once the camera has a RAF to describe, and
    /// every path that uploads one sits behind the `supportsRawConversion` gate the question is
    /// about. Two GFX100S reports carry a `0x2002` from a plain sweep that settles nothing
    /// (2026-09-15).
    ///
    /// It also records whether the upload shows up in `GetObjectHandles`. If it appears as the
    /// conversion buffer's `FUP_FILE.dat`, the harvest deletes it and reads `0xD185` once more to see
    /// whether the buffer went with it.
    ///
    /// Nil when `canHarvestProfile` is false, so nothing was sent. Throws `CameraBusy`, also having
    /// sent nothing, when another operation holds the camera.
    func harvestConversionProfile(raf: Data) async throws(CameraBusy) -> ProfileHarvestOutcome? {
        try await gate.run("profile harvest") { await self.harvestConversionProfileExclusively(raf: raf) }
    }

    private func harvestConversionProfileExclusively(raf: Data) async -> ProfileHarvestOutcome? {
        guard canHarvestProfile, let conv = session.rawConversionTransport, let model = session.connected?.model else {
            AppLog.error(.kitchen, "Profile harvest refused: \(session.connected?.productName ?? "this camera") isn't a trusted, upload-capable body")
            return nil
        }
        let startedAt = CameraCompatibilityReport.timestamp()
        let sessionEpoch = session.epoch.current
        reports.isTracing = true
        defer {
            if session.operationIsCurrent(sessionEpoch) { reports.isTracing = false }
            if session.operationIsCurrent(sessionEpoch) { session.setStatus(.connected) }
        }

        var record = CameraCompatibilityReport.ProfileHarvestRecord(
            at: startedAt, modelID: session.connected?.registryModel?.id,
            firmwareVersion: session.connected?.firmwareVersion,
            rafBytes: raf.count, uploadOutcome: "not attempted")

        // Expected: a refusal, the answer every sweep has recorded and the reason a sweep can't
        // settle this.
        session.setStatus(.working("Harvest: reading the conversion profile…"))
        record.profileBeforeUpload = await describeProfileRead(conv)

        let handlesBefore = try? await conv.getObjectHandles()

        // Unlike a develop, the harvest sends a file from another body anyway: whether the camera
        // refuses one, and at which step, is published but not measured here, so the header's
        // verdict is recorded beside the camera's answer.
        session.setStatus(.working("Harvest: sending the RAF to the camera — this can take a minute…"))
        let origin = RAFHeader(raf)?.origin(for: model) ?? .undetermined
        switch origin {
        case .sameBody: record.rafHeader = "names this body"
        case .otherBody(let other): record.rafHeader = "names \(other.id), not this \(model.id)"
        case .undetermined: break
        }
        do {
            try await conv.sendObject(raf, filename: "harvest.RAF")
            record.uploadOutcome = "accepted"
        } catch {
            record.uploadOutcome = Self.probeFailureMessage(error)
            if case CameraError.ptpError(code: 0x2002) = error {
                record.failureReason = "upload_general_error"
            } else {
                record.failureReason = error.diagnosticReason
            }
            return finishHarvest(record, model: model, sessionEpoch: sessionEpoch)
        }

        var newHandle: UInt32?
        if let before = handlesBefore, let after = try? await conv.getObjectHandles() {
            let created = Set(after).subtracting(before)
            record.uploadCreatedObject = !created.isEmpty
            if created.count == 1 { newHandle = created.first }
        }

        session.setStatus(.working("Harvest: reading the conversion profile…"))
        do {
            let blob = try await conv.readProperty(FujiPTP.Prop.rawConvProfile) ?? Data()
            if blob.isEmpty {
                record.failureReason = "profile_empty"
            } else {
                record.profileLength = blob.count
                record.declaredParams = FujiRawConvProfile.numParams(in: blob)
                record.layoutBase = FujiRawConvProfile.resolveLayout(blob)?.base
                record.layoutDiagnostic = FujiRawConvProfile.layoutDiagnostic(blob)
                record.profileHead = FujiRawConvProfile.hexDump(blob)
                if record.layoutBase == nil { record.failureReason = "conversion_profile_mismatch" }
            }
        } catch {
            record.profileReadError = Self.probeFailureMessage(error)
            if case CameraError.ptpError(code: 0x2002) = error, origin != .sameBody {
                record.failureReason = "raf_from_different_body"
            } else {
                record.failureReason = error.diagnosticReason
            }
        }

        if let handle = newHandle, session.operationIsCurrent(sessionEpoch),
           let info = try? await conv.getObjectInfo(handle),
           info.objectFormat == FujiPTP.rafObjectFormat, info.filename == FujiPTP.rawConversionUploadName,
           session.operationIsCurrent(sessionEpoch) {
            record.objectDeleted = (try? await conv.deleteObject(handle)) != nil
            record.profileAfterDelete = await describeProfileRead(conv)
        }
        return finishHarvest(record, model: model, sessionEpoch: sessionEpoch)
    }

    private func finishHarvest(_ record: CameraCompatibilityReport.ProfileHarvestRecord,
                               model: CameraModel, sessionEpoch: UInt64) -> ProfileHarvestOutcome {
        var summary: String
        if record.uploadOutcome != "accepted" {
            summary = "upload refused — \(record.uploadOutcome)"
        } else if let base = record.layoutBase, let length = record.profileLength {
            summary = String(format: "%d-byte profile, layout resolved at base 0x%X", length, base)
        } else if let length = record.profileLength {
            summary = "\(length)-byte profile, layout unresolved"
        } else {
            summary = "profile refused after the upload — \(record.profileReadError ?? "no data")"
        }
        // The header's verdict sits beside the camera's answer, never inside `uploadOutcome`.
        if let header = record.rafHeader { summary += " (the RAF's header \(header))" }
        AppLog.info(.kitchen, "Profile harvest on \(model.id): \(summary)")
        if session.operationIsCurrent(sessionEpoch) {
            noteInCompatibilityReport("profile harvest: \(summary)")
            recordHarvest(record)
        }
        return ProfileHarvestOutcome(record: record, summary: summary)
    }

    /// One line about what `0xD185` holds right now: a length, "empty", or the refusal.
    private func describeProfileRead(_ conv: RawConversionTransport) async -> String {
        do {
            guard let data = try await conv.readProperty(FujiPTP.Prop.rawConvProfile), !data.isEmpty else {
                return "empty"
            }
            return "\(data.count) bytes"
        } catch {
            return Self.probeFailureMessage(error)
        }
    }

    /// One probe preview: the result as the Kitchen files it, and the bytes the probe reads the
    /// MakerNote from while they are still in hand. Held for one probe step, then let go.
    private struct ProbePreview {
        let result: ConversionResult
        let jpeg: Data
    }

    /// Trigger a preview-resolution conversion and hand back the JPEG, for the probe only.
    private func convertPreviewForProbe(_ conv: RawConversionTransport, filename: String,
                                        sessionEpoch: UInt64) async -> Result<ProbePreview, Error> {
        do {
            let before = Set(try await conv.getObjectHandles())
            guard session.operationIsCurrent(sessionEpoch) else { throw CameraError.disconnectedDuringOperation }
            try await conv.writeProperty(FujiPTP.Prop.startRawConversion, FujiEncoding.packU16(0))
            let handle = try await waitForConvertedObject(conv, excluding: before, sessionEpoch: sessionEpoch)
            var result = ConversionResult(sourceFilename: filename, success: false, clampedFields: [])
            let jpeg = try await retrieveConversionOutput(conv, handle: handle, sessionEpoch: sessionEpoch,
                                                          result: &result)
            return .success(ProbePreview(result: result, jpeg: jpeg))
        } catch {
            return .failure(error)
        }
    }

    private static func probeFailureMessage(_ error: Error) -> String {
        if case CameraError.ptpError(let code) = error {
            return String(format: "0x%04X %@", code, FujiPTP.responseName(code) ?? "")
        }
        return (error as? CameraError)?.errorDescription ?? error.localizedDescription
    }
}
