import Foundation

/// Errors surfaced from the camera layer. `message` is user-facing and names a specific cause and
/// next step rather than a generic failure.
enum CameraError: LocalizedError, Equatable {
    case noDeviceConnected
    case permissionDenied
    /// Camera access is granted but iOS refused the separate "contents" grant without prompting —
    /// a stuck per-bundle-id record on the device (see `CameraDeviceBrowser.ensureAuthorized()`).
    /// Distinct from `permissionDenied` because the Camera switch is already on; the one to look at
    /// is under Files and Folders, and reinstalling does not clear it.
    case contentsAccessUnavailable
    case wrongUSBMode
    case chargeOnlyCableOrAdapter
    case unsupportedModel(name: String)
    case writeBlocked(reason: String)
    /// The slot select failed. `code` is the camera's response when it refused the select, which
    /// says why — a slot the body doesn't have, a body too busy to take commands — and nil when
    /// the failure wasn't a response at all. Build it with `slotSelectFailed(_:after:)`.
    case slotSelectFailed(slot: Int, code: UInt16?)
    /// The camera answered `OK` to the slot select and went on reporting a different slot.
    ///
    /// Distinct from `slotSelectFailed`, which is a refusal — this one *succeeds* at the PTP level
    /// and is the more dangerous of the two, because every read and write after it addresses a slot
    /// the user did not choose and agrees with itself while doing so.
    case slotSelectIgnored(asked: Int, got: Int?)
    case sessionFailed(String)
    case ptpError(code: UInt16)
    case readBackMismatch(field: String)
    case disconnectedDuringOperation
    case timeout
    case rawConversionUnsupported
    case conversionTimedOut
    case noOutputProduced
    case conversionProfileMismatch(detail: String)
    /// The camera took the upload, then answered `0x2002` to the profile read, and the file's header
    /// gave no body to check against. A RAF from another camera is the published cause of exactly
    /// this (zgrimz/fujifilm-ptp-reference `docs/05-raw-conversion.md#prerequisites`), so the message
    /// names it as a known cause, not the diagnosis.
    case rafFromDifferentBody(filename: String)
    /// The file's own header names another body (`RAFHeader`), so nothing was sent.
    case rafShotOnAnotherBody(filename: String, shotOn: String, connected: String)
    /// The upload drew `0x2002` from a file whose header names the connected body, which rules a
    /// RAF from another body out and leaves the camera's General Error unexplained.
    case uploadRefused(filename: String)
    /// The upload drew `0x2002` and the file's header gave no body to check against. An upload
    /// refusal alone doesn't establish a cause (same section as `rafFromDifferentBody`), so none is
    /// named.
    case uploadRefusedWithoutCause(filename: String)
    /// `RAFSource.load` threw: the picked file went away or can't be read, so nothing was sent.
    case rafUnreadable
    /// The file doesn't start with the RAF magic, so nothing was sent. `kind` is what the sniffer
    /// made of it (`FileKind.detect`), so the message can name a JPEG as one.
    case notARAF(filename: String, kind: FileKind)

    var errorDescription: String? { message }

    var message: String {
        switch self {
        case .noDeviceConnected:
            return "No camera detected. Connect your Fujifilm camera with a USB data cable and set it to “USB RAW Conv./Backup Restore” mode."
        case .permissionDenied:
            return "Fuji Cookbook needs permission to communicate with your camera. Allow camera access when iOS asks, or enable it in Settings, then reconnect."
        case .contentsAccessUnavailable:
            return "iOS is refusing Fuji Cookbook access to your camera's contents. That is a second permission, separate from Camera: Settings → Privacy & Security → Files and Folders → Fuji Cookbook. If that switch is off and won't stay on, iOS has a stuck record for this app on this device that reinstalling doesn't clear. Send a report from Settings → Help & Feedback → Report a Problem; the log inside it carries what iOS returned."
        case .wrongUSBMode:
            return "The camera is connected but isn't in the right USB mode. On the camera, set Connection Setting → USB Mode to “USB RAW Conv./Backup Restore” (or your model's equivalent), then reconnect."
        case .chargeOnlyCableOrAdapter:
            return "The camera was seen but no data connection was established. This is usually a charge-only cable or an unpowered/non-Apple adapter. Use a USB data cable (the one that shipped with the camera is a safe choice)."
        case .unsupportedModel(let name):
            return "“\(name)” isn't a recognized model and didn't identify itself over USB with a product name, serial number and firmware version, so Fuji Cookbook won't write recipes to it."
        case .writeBlocked(let reason):
            return reason.isEmpty ? "Writing to this camera isn't enabled yet." : reason
        case .slotSelectIgnored(let asked, let got):
            return "The camera didn't switch to slot C\(asked) — it's still on \(got.map { "C\($0)" } ?? "another slot"). Nothing was written. Disconnect, reconnect and try again."
        case .slotSelectFailed(let slot, let code):
            let answer = code.map { ": it answered \(Self.responseLabel($0))" } ?? ""
            return "Couldn't select custom slot C\(slot) on the camera\(answer). Nothing was changed."
                + Self.remedy(for: code)
        case .sessionFailed(let detail):
            return "Couldn't start a session with the camera: \(detail)"
        case .ptpError(let code):
            let name = FujiPTP.responseName(code).map { " — \($0)" } ?? ""
            return String(format: "The camera reported a protocol error (0x%04X)%@.", code, name)
                + Self.remedy(for: code)
        case .readBackMismatch(let field):
            return "Write verification failed: after writing, “\(field)” didn't read back as expected. The slot may not have been fully updated."
        case .disconnectedDuringOperation:
            return "The camera disconnected during the operation. Reconnect and check the affected slot before retrying."
        case .timeout:
            return "The camera stopped responding. Check the cable and that the camera is powered on."
        case .rawConversionUnsupported:
            return "RAW conversion isn't available for this camera. It requires a connected, recognized body whose conversion protocol has been verified, in “USB RAW Conv./Backup Restore” mode."
        case .conversionTimedOut:
            return "The camera didn't return a converted JPEG in time. Keep the app in the foreground and the camera awake, then try again."
        case .noOutputProduced:
            return "The conversion finished but no JPEG came back from the camera. Nothing was saved."
        case .conversionProfileMismatch(let detail):
            return "This camera's conversion profile doesn't match the layout Fuji Cookbook understands (\(detail)). To protect the conversion, no recipe was applied."
        case .rafFromDifferentBody(let filename):
            return "The camera accepted “\(filename)” but returned no conversion profile for it (General Error 0x2002), so no recipe was applied. A RAW file shot on another camera is a known cause: Fujifilm cameras only develop their own RAW files, and even another camera of the same model won't work."
        case .rafShotOnAnotherBody(let filename, let shotOn, let connected):
            return "“\(filename)” was shot on a different camera (\(shotOn)), so this \(connected) can't develop it. Fujifilm cameras only develop their own RAW files, and even another camera of the same model won't work. Nothing was sent."
        case .uploadRefused(let filename):
            return "The camera refused the upload of “\(filename)” (General Error 0x2002). The file names this camera, so a RAW file from another body isn't the cause. Reconnect and try again; if it keeps happening, send a report from Settings."
        case .uploadRefusedWithoutCause(let filename):
            return "The camera refused the upload of “\(filename)” (General Error 0x2002) without giving a reason. Reconnect and try again; if it keeps happening, send a report from Settings."
        case .rafUnreadable:
            return "Couldn't read the selected RAW file. Choose the file again."
        case .notARAF(let filename, let kind):
            let what = kind == .unknown ? "isn't a Fujifilm RAW file"
                                        : "is a \(kind.displayName), not a Fujifilm RAW file"
            return "“\(filename)” \(what), so the camera can't develop it. Pick a .RAF file this camera shot. Nothing was sent."
        }
    }

    /// `Device Busy (0x2019)`, or the bare code for a response PTP gives no name.
    private static func responseLabel(_ code: UInt16) -> String {
        FujiPTP.responseName(code).map { "\($0) (\(PTPHex.code(code)))" } ?? PTPHex.code(code)
    }

    /// The next step for a response the record gives one for, as a sentence to append, else "".
    /// Device Busy is the one: a body left busy by a conversion that never completed stays busy
    /// until it is switched off and on (`FujiPTP.responseDeviceBusy`).
    private static func remedy(for code: UInt16?) -> String {
        guard code == FujiPTP.responseDeviceBusy else { return "" }
        return " A camera can stay busy after a develop that didn't finish: turn it off and on again, then reconnect."
    }
}

extension CameraError {
    /// The `slotSelectFailed` for a select that threw `error`, keeping the camera's response code
    /// when the camera refused it. Every slot-select site builds its error here, so none of them
    /// reports a refusal without what the camera answered.
    static func slotSelectFailed(_ slot: Int, after error: Error) -> CameraError {
        guard case CameraError.ptpError(let code) = error else { return .slotSelectFailed(slot: slot, code: nil) }
        return .slotSelectFailed(slot: slot, code: code)
    }
}

extension CameraError {
    /// True when this error is the camera *answering*, which is proof the PTP session is alive.
    ///
    /// A response code — even a refusal — travelled back down the cable, so whatever went wrong,
    /// the session did not. This matters because the session-health probes ask for one property
    /// (`0xD18C`) that a body in a card-reader USB mode does not implement: a tester's GFX100S
    /// (2026-09-15) answered `0x200A` to every ping, and reading that as a dropped connection
    /// turns one wrong menu setting into a teardown-and-reconnect loop every five seconds until
    /// recovery gives up.
    ///
    /// The exceptions are the codes where the camera's answer *is* "that session is gone": the
    /// body replied, but replied about a session this app no longer has.
    ///
    /// A response code is proof of the camera only if the camera produced it, and the app sees codes
    /// through ImageCaptureCore, not off the cable. No run has shown the framework inventing one for
    /// a body that is gone — it reports a missing device as an `NSError`, which `sessionSurvives`
    /// already reads as loss — so the policy stands on that, not on the code's origin being certain.
    var provesCameraAnswered: Bool {
        guard case .ptpError(let code) = self else { return false }
        return !CameraError.sessionStateResponses.contains(code)
    }

    /// `Session Not Open`, `Invalid TransactionID`, `Session Already Open` — see `FujiPTP.responseName`.
    private static let sessionStateResponses: Set<UInt16> = [0x2003, 0x2004, 0x201E]

    /// Coarse, non-identifying label for log lines and diagnostic reports.
    ///
    /// Associated values are deliberately dropped: `unsupportedModel`'s name and
    /// `rafFromDifferentBody`'s filename are the user's own device and files, and
    /// `writeBlocked`/`sessionFailed` carry prose that would fragment the breakdown into as many
    /// buckets as there are phrasings. `ptpError` is the one exception — its code is a protocol
    /// constant from the camera, and which code a body returns is the fact a report is for.
    var diagnosticReason: String {
        switch self {
        case .noDeviceConnected: return "no_device"
        case .permissionDenied: return "permission_denied"
        case .contentsAccessUnavailable: return "contents_access_unavailable"
        case .wrongUSBMode: return "wrong_usb_mode"
        case .chargeOnlyCableOrAdapter: return "charge_only_cable"
        case .unsupportedModel: return "unsupported_model"
        case .writeBlocked: return "write_blocked"
        case .slotSelectFailed: return "slot_select_failed"
        case .slotSelectIgnored: return "slot_select_ignored"
        case .sessionFailed: return "session_failed"
        case .ptpError(let code): return String(format: "ptp_0x%04X", code)
        case .readBackMismatch: return "read_back_mismatch"
        case .disconnectedDuringOperation: return "disconnected_during_operation"
        case .timeout: return "timeout"
        case .rawConversionUnsupported: return "raw_conversion_unsupported"
        case .conversionTimedOut: return "conversion_timed_out"
        case .noOutputProduced: return "no_output_produced"
        case .conversionProfileMismatch: return "conversion_profile_mismatch"
        case .rafFromDifferentBody, .rafShotOnAnotherBody: return "raf_from_different_body"
        case .uploadRefused, .uploadRefusedWithoutCause: return "upload_general_error"
        case .rafUnreadable: return "file_unreadable"
        case .notARAF: return "not_a_raf"
        }
    }
}

/// The same label for any error reaching a log site, so a non-`CameraError` still lands in a
/// named bucket rather than having its `localizedDescription` — which can quote user content —
/// interpolated into a log line.
extension Error {
    var diagnosticReason: String {
        (self as? CameraError)?.diagnosticReason
            ?? (self as? FujiPTP.InvalidDataset)?.diagnosticReason
            ?? "other"
    }
}

/// What a develop is willing to say about itself in a shared report.
///
/// The push path writes `pushes[]` and the connect path writes `deviceInfo` and `slots`; a develop
/// owes the report the same, because RAW conversion is enabled on more bodies than it has been
/// verified on.
///
/// **Every field here is deliberately non-identifying**, and that constraint is the reason this
/// type exists rather than the report reaching into `ConversionResult` directly. `sourceFilename`,
/// `errorMessage` and `diagnostics` all interpolate the user's own file names, and the compatibility
/// report has no field for a photo or a file name and must not grow one. `failureReason` is the
/// coarse label the Kitchen log already uses for the same reason.
struct CookEvidence: Equatable {
    /// Length of the `0xD185` profile the camera returned. A length the record's profile table
    /// doesn't hold (zgrimz/fujifilm-ptp-reference `docs/06-conversion-profile.md`) is a finding on
    /// its own.
    var profileLength: Int?
    /// Byte offset `resolveLayout` settled on, or nil when it refused the blob — which is the abort
    /// that stops an unfamiliar body before a byte is written.
    var layoutBase: Int?
    var declaredParams: Int?
    /// Whether the camera read the patched profile back as written. Nil when the develop never got
    /// that far. `false` means the JPEG may not reflect the recipe at all.
    var profileVerified: Bool?
    /// Explicit verification state; the legacy boolean remains for older reports.
    var profileVerification: String?
    var outputValidation: String?
    var cleanupOutcome: String?
    /// Which cells disagreed on the read-back, already rendered by
    /// `FujiRawConvProfile.verificationMismatches`.
    var mismatches: [String] = []
    /// How Dynamic Range was resolved against the frame's own headroom: `applied`, `untouched`,
    /// `cappedToAsShot(400->200)`, `autoResolved(200)`. The clamp is one-directional, so this is
    /// where a "why doesn't it look like the recipe" complaint gets settled.
    var dynamicRange: String?
    /// `1` (full resolution) or `0` (downscaled preview) — the `0xD183` trigger value.
    var fullResolution: Bool?
    /// Size of the JPEG the camera produced. Not the photo, and not derived from it: a plausible
    /// byte count is how you tell "developed nothing" from "developed something wrong".
    var outputBytes: Int?
    /// The coarse failure label, never the user-facing message: `raf_from_different_body`,
    /// `conversion_profile_mismatch`, a `diagnosticReason`, and so on.
    var failureReason: String?
}

/// The outcome of converting one RAF through the camera — a per-item result, like
/// `SlotWriteResult`.
struct ConversionResult: Identifiable, Equatable {
    let id = UUID()
    /// The source RAF's filename, for labeling results and naming the saved JPEG.
    let sourceFilename: String
    /// True once the camera's JPEG is validated and on disk at `recoveryFileURL`.
    var success: Bool
    /// Recipe fields that were clamped to the model's supported range before conversion.
    var clampedFields: [String]
    /// Non-fatal problems worth telling the user about, such as "the camera never confirmed the
    /// conversion profile", which means this JPEG may not reflect the recipe. Separate from
    /// `errorMessage`: the develop still produced an image, and refusing it outright would block
    /// renders that are probably fine.
    var warnings: [String] = []
    /// Decisions the develop made on the recipe's behalf, where the recipe couldn't be followed
    /// literally and the difference is visible in the image — currently Dynamic Range resolved
    /// against the frame's own headroom, and D-Range Priority. Deliberately neither
    /// `clampedFields` (these aren't clamps, and would be mislabelled "Clamped to camera range") nor
    /// `warnings` (nothing went wrong, and every one of these would otherwise become a
    /// `isReportableAnomaly` in the shared problem report — DR Auto is the default in
    /// `RecipeSettings.neutral`). A note explains a render; it doesn't flag one.
    var notes: [String] = []
    var errorMessage: String?
    /// Optional byte-level report of the D185 profile patch, for diagnosing hardware color issues.
    var diagnostics: String? = nil
    /// The non-identifying facts about this develop, for the compatibility report.
    var evidence = CookEvidence()
    /// Where the developed JPEG is. The service writes it here before the camera's copy is removed,
    /// and no result carries the bytes: the store reads the file when it saves the batch and the
    /// results sheet reads it on demand, so a batch of N develops has one JPEG outside the library
    /// at any point. The library's save removes the file; a failed save keeps it, which is what the
    /// results sheet's "Export saved recovery copy…" offers.
    var recoveryFileURL: URL? = nil
    /// An unconfirmed mutation forbids automatically starting the next batch item, even when
    /// the JPEG was safely saved before an uncertain cleanup response.
    var requiresReconnect = false

    /// Whether this result is worth flagging in the on-device log: the conversion failed, it raised
    /// a warning (`warnings`), or fields were clamped. A clean success is
    /// routine and logs nothing — the log exists so a shared problem report shows the develops
    /// that may not reflect the recipe, not every develop that happened.
    var isReportableAnomaly: Bool { !success || !warnings.isEmpty || !clampedFields.isEmpty }

    /// The result of a develop the operation gate refused: nothing reached the camera. The refusal
    /// is recorded as the `camera_busy` failure reason, which the cook record and the report keep.
    static func refusedBecauseBusy(sourceFilename: String) -> ConversionResult {
        var result = ConversionResult(sourceFilename: sourceFilename, success: false, clampedFields: [],
                                      errorMessage: "Another camera operation is still running. This develop wasn't started.")
        result.evidence.failureReason = "camera_busy"
        return result
    }

    /// Suggested output filename: `<source basename>.jpg`.
    var outputFilename: String {
        let base = (sourceFilename as NSString).deletingPathExtension
        return (base.isEmpty ? "converted" : base) + ".jpg"
    }
}

/// One recipe's rendering of a single source RAF, for the **Test Kitchen** side-by-side comparison.
struct TestKitchenVersion: Identifiable {
    let id = UUID()
    /// The recipe (or camera-slot) name this version was developed with.
    let recipeName: String
    /// The recipe's film simulation, for a compact subtitle under the image.
    let filmSimulation: String?
    /// The underlying conversion outcome (jpeg / clamps / error), exactly as `cook` returned it.
    let result: ConversionResult
}

/// All developed versions of one source RAF — up to one per selected recipe — grouped so the
/// Test Kitchen can show them side by side.
struct TestKitchenComparison: Identifiable {
    let id = UUID()
    let sourceFilename: String
    var versions: [TestKitchenVersion]
}

/// Metadata about a connected camera, so the user can see which model and firmware was detected.
struct ConnectedCamera: Equatable {
    let productName: String
    let firmwareVersion: String?
    /// How the product name resolved — the model *and* how much to trust it.
    let identification: ModelIdentification
    /// The Demo Camera rather than a body on the cable. Decided by the transport at connect, not
    /// by the model: a faulted demo carries a real body's product name and resolves to its
    /// registry entry, so `model?.id == demoModelID` misses it.
    let isDemo: Bool
    /// What the app will do with this body, decided once at connect by `CameraConnector` through
    /// `WriteDecision`.
    let writeAccess: WriteAccess
    /// What the body answered at connect. Empty until the slot read has run.
    var observed = ObservedCapabilities()

    var model: CameraModel? { identification.model }

    /// This camera with the connect's slot read filed.
    func observing(_ slotRead: WalkResult) -> ConnectedCamera {
        var copy = self
        copy.observed.slotRead = slotRead
        return copy
    }

    /// This camera with the staged first write's outcome filed.
    func recording(firstWrite: FirstWriteOutcome) -> ConnectedCamera {
        var copy = self
        copy.observed.firstWrite = firstWrite
        return copy
    }

    /// This camera with write access decided.
    func deciding(_ access: WriteAccess) -> ConnectedCamera {
        ConnectedCamera(productName: productName, firmwareVersion: firmwareVersion, identification: identification,
                        isDemo: isDemo, writeAccess: access, observed: observed)
    }

    /// The Camera tab's unsupported-camera card: a body with no identity, or an unlisted body its
    /// slot read refused. Not one still being read, and not one that was granted.
    var isUnsupported: Bool {
        switch identification {
        case .unknown: return true
        case .unlisted: if case .refused = writeAccess { return true }; return false
        case .exact, .alias, .heuristic: return false
        }
    }

    /// A recognized body the app selects no slot on, once that is decided: nothing to offer slots
    /// for, so the Camera tab explains the body instead.
    var slotsUnreachable: Bool { model != nil && !maySelectSlots && writeAccess != .undecided }

    /// Whether the app may write `FujiPTP.Prop.slotSelector` to put this body on a chosen slot.
    ///
    /// Wider than `isWritable`: selecting a slot is how a slot gets *read*, so a body the app
    /// doesn't write to still needs it. A trusted `.readWrite` entry keeps the registry's word
    /// (`supportsSlotProtocol`): a just-replugged GFX100S has answered neither the selector read nor
    /// its restore and still taken every select (`SlotReader.refresh`). A `.blocked` entry never
    /// selects. Any other body selects once its selector has answered a bank number at connect.
    var maySelectSlots: Bool {
        switch identification {
        case .unknown:
            return false
        case .exact(let model), .alias(let model, _):
            switch model.writeSupport {
            case .blocked: return false
            case .readWrite: return model.supportsSlotProtocol
            case .untested: return observed.hasBankBlock
            }
        case .heuristic(let model, _), .unlisted(let model):
            if case .blocked = model.writeSupport { return false }
            return observed.hasBankBlock
        }
    }
    /// The registry entry, for anything that persists or compares a model id
    /// (`ModelIdentification.registryModel`).
    var registryModel: CameraModel? { identification.registryModel }

    var isWritable: Bool {
        if case .granted = writeAccess { return true }
        return false
    }

    /// The permission a writer takes as its parameter, when the body has one.
    var writePermission: WritePermission? {
        if case .granted(let permission) = writeAccess { return permission }
        return nil
    }

    /// What the push screen says before a write to this body, from what its permission rests on
    /// (`WritePermission.Grounds.pushCaveat`). Nil without a permission, when no push is offered.
    var pushCaveat: String? { writePermission?.grounds.pushCaveat }

    /// What the Camera Test tells a tester about this body's evidence, from what its permission rests
    /// on (`WritePermission.Grounds.testerNote`). Nil without a permission, as ``pushCaveat`` is: a
    /// trusted entry is granted at identification, so the bodies left without one are mid-walk or
    /// refused, and their entry's level note says why writing is on when it isn't.
    var testerNote: String? { writePermission?.grounds.testerNote }

    /// The one sentence explaining why a push isn't offered, from whichever gate refused it; nil
    /// when it is offered.
    var writeBlockReason: String? {
        switch writeAccess {
        case .granted: return nil
        case .undecided: return "The camera's slots are still being read."
        case .refused(let refusal): return refusal.reason(productName: productName)
        }
    }

    /// The capability seal: what the app will do with this body, and how firmly it knows.
    ///
    /// One rendering for the Camera tab's status card and the guided test, which asks the tester to
    /// confirm it and then records what they were looking at. Two renderings of the seal that
    /// could disagree would make that record worth less than nothing.
    ///
    /// The seal says one thing: whether a write to this body has been read back — here, in this
    /// session, or in the hardware or owner report its registry entry rests on
    /// (`WritePermission.Stage`). Every other body carries the caveat until its first push here
    /// verifies it, whatever its entry says: a community report has no write through this app
    /// behind it, shared architecture has already failed to predict a bank path once (the X-Pro3),
    /// and a body granted on its own answers at connect has no report at all. The caveat clears
    /// when `CameraSession.markWriteVerified()` runs and comes back with the next connection.
    var capabilityBadge: (text: String, symbol: String) {
        guard model != nil else { return ("Unrecognized model — writes blocked", "questionmark.diamond") }
        switch writeAccess {
        case .undecided:
            return ("Reading slots…", "hourglass")
        case .refused(let refusal):
            switch refusal {
            case .blockedByRecord, .noBankBlock:
                return ("Read-only · no USB slots", "lock.fill")
            case .noIdentity, .selectorUnreadable, .walkFailed, .selectIgnored, .noBanks, .selectorNotRestored:
                return identification.isGuess ? ("Read-only · matched by name", "questionmark.circle")
                                              : ("Read-only", "lock.fill")
            }
        case .granted(let permission):
            switch permission.stage {
            case .verified: return ("Read & Write", "checkmark.seal.fill")
            case .unverified: return ("Read & Write · not yet tested", "checkmark.seal")
            }
        }
    }
}

/// A custom slot as read from the camera.
struct CameraSlot: Identifiable, Equatable {
    let index: Int            // 1 … slotCount
    var label: String         // "C1"
    var name: String?
    var isOccupied: Bool
    var settings: RecipeSettings?
    /// Raw per-property bytes preserved for the patch-based safe write.
    var rawProperties: [UInt16: Data]
    var unsupportedFields: [String: JSONValue]
    /// Settings the slot holds that no recipe can carry (`DecodedProfile.cameraOnlyFields`):
    /// `["White Balance": "Custom 1"]`. Shown beside the slot; never a reason to flag it as unread.
    var cameraOnlyFields: [String: String] = [:]

    var id: Int { index }

    /// The on-camera name, or nil when the slot has no (or an empty) name.
    var resolvedName: String? {
        guard let name, !name.isEmpty else { return nil }
        return name
    }

    /// User-facing name for an occupied slot: the on-camera name, else the film simulation.
    var displayName: String {
        resolvedName ?? settings?.filmSimulation?.displayName ?? "Occupied"
    }
}

/// A value the camera returned that the codec could not interpret, or interpreted into a number the
/// model's own range says is impossible.
///
/// Recorded rather than silently dropped or coerced to a default: on a body nobody has tested, a
/// divergent encoding is the expected finding, and a finding nothing records is not one — the
/// tester sees a plausible recipe and never knows to report it.
struct DecodeDivergence: Equatable {
    enum Kind: Equatable {
        /// No entry in our table. The recipe field is left unset — never guessed at.
        case unrecognized
        /// It decoded, but outside `CameraModel.range(for:)`. The value is **kept** — dropping a
        /// plausibly mis-scaled number loses more than it gains, and `RecipeCompatibility.clamped`
        /// already clamps on the way out — and flagged, because a body storing tone ×100 produces a
        /// recipe that looks entirely reasonable and is wrong by a factor of ten.
        case outOfRange(min: Double, max: Double)
        /// A value the app knows and no recipe can carry. Custom white balance 1–3 is a measurement
        /// stored on that one camera, not a setting a recipe describes: the recipe field is left
        /// unset, and the slot says what the camera holds so a tester's menu comparison still
        /// matches. Not a mis-read, so it stays out of `unsupportedFields` and the "couldn't read"
        /// warnings that key off it.
        case cameraOnly(label: String)
    }

    /// The preset property code, e.g. `0xD199`.
    let code: UInt16
    /// `PresetProp.debugName`, not `RecipeField.displayName`: four codes share "White Balance", and
    /// which one a body disagreed about is the whole fact.
    let property: String
    let field: RecipeField?
    /// The unsigned 16-bit view. WB modes and the High ISO NR lookup are bit patterns (`0x8001`…),
    /// which the signed view prints as negatives.
    let value: Int
    let kind: Kind

    /// `0xD199 White Balance = 0x8009 (32777)` — the one line the log, the report and the recipe's
    /// preserved-fields map all use, so the three never drift into separate accounts.
    var summary: String {
        "\(PTPHex.code(code)) \(property) = \(PTPHex.code(UInt16(truncatingIfNeeded: value))) (\(value))"
    }

    /// What it cost, in the terms the tester sees on screen.
    var consequence: String {
        switch kind {
        case .unrecognized:
            return "not a value this app recognizes — \(property) left unread"
        case .outOfRange(let min, let max):
            return "outside the expected \(Self.trim(min))…\(Self.trim(max)) — kept as read"
        case .cameraOnly(let label):
            return "\(label), a setting on the camera itself rather than a recipe value — \(property) left unset"
        }
    }

    /// `-4` rather than `-4.0`, so a whole-number range doesn't read like a measurement.
    static func trim(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}

/// The decoded contents of a slot.
struct DecodedProfile: Equatable {
    var settings: RecipeSettings
    var name: String?
    var unsupportedFields: [String: JSONValue]
    /// Every raw property value read from the slot, kept so a later write can preserve the bytes of
    /// fields the app doesn't edit.
    var rawProperties: [UInt16: Data]
    /// Everything the decode could not account for, in property order. Empty on a body whose
    /// encodings match ours — which is the assertion the codec's control test makes, and what stops
    /// this becoming noise on the one body that is verified.
    var divergences: [DecodeDivergence] = []
    /// Settings the slot holds that no recipe can carry, by field display name — `["White Balance":
    /// "Custom 1"]`. Shown beside the slot and in the menu comparison, never imported. See
    /// `DecodeDivergence.Kind.cameraOnly`.
    var cameraOnlyFields: [String: String] = [:]
}

/// What happened to one property in the encode set.
///
/// Kept apart because a field the camera refused, one the loop never reached, one written and
/// held, and one written that then didn't stick each call for a different action from the tester.
enum FieldOutcome: Equatable {
    /// The camera accepted the write and read it back as written.
    case written
    /// The camera refused the write. `code` is its PTP response when it gave one — which is the
    /// single most useful fact for characterizing an unverified body.
    case rejected(code: UInt16?)
    /// The loop never got here: an earlier step threw, or the session dropped mid-push.
    case notAttempted
    /// The camera accepted the write and then reported something else. More dangerous than a
    /// rejection, because nothing failed loudly.
    case mismatched(wrote: Data, read: Data?)
    /// Written, but the read-back never happened, so whether it stuck is unknown.
    case unverified
    /// A send may have reached the camera, but no valid completion established its outcome.
    case outcomeUnknown
}

/// One property's fate, named unambiguously.
struct FieldResult: Identifiable, Equatable {
    let code: UInt16
    /// `PresetProp.debugName`, not `RecipeField.displayName`. Four property codes (D199, D19A,
    /// D19B, D19C) share the display name "White Balance", and which one a body refused is the
    /// whole fact.
    let field: String
    /// Housekeeping properties (image size, colour space, Lens Modulation Optimizer) are passed through
    /// rather than authored, and some bodies legitimately refuse them. They're recorded, but they
    /// don't decide the slot's headline outcome.
    let isRecipeField: Bool
    var outcome: FieldOutcome
    /// The bytes this push intended for the property, from the encode set. Recorded for every
    /// outcome, not only a mismatch: "what did D192 get" is the question a film-simulation
    /// complaint asks. Nil for the pre-flight entries that never had a property code.
    var wrote: Data? = nil

    var id: UInt16 { code }

    /// The camera was asked and said no — as opposed to never being asked. Used when deciding
    /// whether a push touched the camera at all.
    var isRejectedOutright: Bool {
        if case .rejected = outcome { return true }
        return false
    }
}

/// What the camera holds after a push. Four states, so that a write followed by a lost read-back
/// is not reported as failure. Persisted by its raw value in pushes, Camera Test trials and restore
/// verifications, so a case is never renamed.
enum SlotOutcome: String, Codable, Equatable {
    /// Every recipe field intended for this slot is on the camera and was read back.
    case applied
    /// Some of it landed; the rest was refused or never attempted. The slot holds a mix.
    case partiallyApplied
    /// Nothing reached the camera. The only state in which "left unchanged" is a true statement.
    case notWritten
    /// Writes landed, but the read-back could not run, so what the slot holds is unverified.
    case unknown
}

/// Result of writing one slot.
struct SlotWriteResult: Identifiable, Equatable {
    let slot: Int
    var outcome: SlotOutcome
    var nameWritten: Bool
    var nameApplied: String?
    var clampedFields: [String]
    /// Every property in the encode set, including ones never attempted — so "what is my slot
    /// holding now" is answerable rather than inferred from what happens to be listed.
    var fields: [FieldResult]
    var errorMessage: String?
    /// What the slot's film simulation read back as after the push — the value, not the status: a
    /// passthrough can write PROVIA from the slot's own bytes, and this is what lets the results
    /// screen say which simulation landed.
    var filmSimulationReadBack: FilmSimulation? = nil
    /// What the slot's dynamic range read back as after the push, for the same reason: a passthrough
    /// verifies against itself, and "Written and verified" alone can sit over a DR200 that a DR-Auto
    /// recipe never asked for (docs/fuji-recipe-ptp-protocol.md §"What read-back verification cannot
    /// catch"). nil when D190 read back as something no `DynamicRange` case covers — saying nothing
    /// beats naming the wrong one.
    var dynamicRangeReadBack: DynamicRange? = nil
    /// Compatibility issues that changed what was written before the camera saw it — a film
    /// simulation the body lacks, none set at all, colour on a monochrome sim.
    var advisories: [String] = []
    /// Facts about the *bank* that a refusal revealed and that don't touch the recipe — see
    /// `imageSizeFixedByBank`. Rendered quietly (an info line, not a warning): nothing went wrong
    /// with the push, the camera just said something about itself worth passing on.
    var notes: [String] = []
    /// Name command/readback result, independent of recipe-field outcomes.
    var nameOutcome: FieldOutcome? = nil
    /// How the staged first write ended, when this push staged one (`StagedWrite`). Nil on an
    /// unstaged push: a verified body, a restore, or a recipe that changes neither candidate.
    var firstWrite: FirstWriteOutcome? = nil
    /// Set when `CameraOperationGate` refused this write because another operation held the camera.
    /// Nothing was sent, so `outcome` is `.notWritten`. Only `refused(slot:by:)` sets it: the
    /// initializer below leaves it out.
    private(set) var refusedBy: CameraBusy? = nil

    var id: Int { slot }

    init(slot: Int, outcome: SlotOutcome, nameWritten: Bool, nameApplied: String? = nil, clampedFields: [String],
         fields: [FieldResult], errorMessage: String? = nil, filmSimulationReadBack: FilmSimulation? = nil,
         dynamicRangeReadBack: DynamicRange? = nil, advisories: [String] = [], notes: [String] = [],
         nameOutcome: FieldOutcome? = nil, firstWrite: FirstWriteOutcome? = nil) {
        self.slot = slot
        self.outcome = outcome
        self.nameWritten = nameWritten
        self.nameApplied = nameApplied
        self.clampedFields = clampedFields
        self.fields = fields
        self.errorMessage = errorMessage
        self.filmSimulationReadBack = filmSimulationReadBack
        self.dynamicRangeReadBack = dynamicRangeReadBack
        self.advisories = advisories
        self.notes = notes
        self.nameOutcome = nameOutcome
        self.firstWrite = firstWrite
    }

    /// The result of a write the operation gate refused: nothing reached the camera.
    static func refused(slot: Int, by busy: CameraBusy) -> SlotWriteResult {
        var result = SlotWriteResult(slot: slot, outcome: .notWritten, nameWritten: false, nameApplied: nil,
                                     clampedFields: [], fields: [],
                                     errorMessage: "Another camera operation is still running. Nothing was written.")
        result.refusedBy = busy
        return result
    }

    /// `D18E` Image Size refused with `0x201C` while the recipe itself wrote. Seen on an X-T50
    /// (fw 1.32, 2026-09-06): C1 refused it on every push while C2–C7 took the identical byte. The
    /// banks that refused had SPORTS FINDER MODE on, which fixes Image Size at P while the bank
    /// still *reports* L — a correlation, with no on/off test on one bank. DIGITAL TELE-CONV. has
    /// that test: the same bytes refused with it on and accepted with it off. HDR is untested. None
    /// of the three is among the 23 bank properties, so the cause is invisible; the signature isn't.
    /// A USB capture of X RAW Studio shows `D18E` writing into C1 on an X-T50 fine, so this is the
    /// bank, not the slot. `0x200A` is deliberately excluded: "not supported" means something else.
    var imageSizeFixedByBank: Bool {
        guard let size = fields.first(where: { $0.code == FujiPTP.PresetProp.imageSize.rawValue }),
              case .rejected(let code) = size.outcome, code == FujiPTP.responseInvalidDevicePropValue
        else { return false }
        return recipeFields.contains { $0.outcome == .written }
    }

    /// The recipe fields that decide the headline outcome.
    var recipeFields: [FieldResult] { fields.filter(\.isRecipeField) }

    /// Fields the camera refused, with its response code where it gave one. The pre-flight
    /// entries — fields the model doesn't have, never sent — are excluded: the camera never saw
    /// them, and listing them under "Refused by the camera" would be a lie about the body.
    var rejected: [FieldResult] {
        recipeFields.filter { field in
            guard field.code != 0, case .rejected = field.outcome else { return false }
            return true
        }
    }

    /// Why a refused **Dynamic Range** was most likely refused, when one was.
    ///
    /// `0x201C` on D190 is almost never a bug and almost always the camera enforcing the ISO floor:
    /// DR200 needs the slot's own ISO at 2× base and DR400 at 4×, and the ISO is not one of the 23
    /// bank properties. Measured on an X-T50 (fw 1.32, base ISO 125, 2026-09-17): at
    /// ISO 125 DR200 and DR400 were refused while DR100 and Auto went through; at ISO 500 all four
    /// went through.
    ///
    /// The other cause — D-Range Priority locking Dynamic Range out — the app *can* see, at `D191`,
    /// and the push clears it before writing a dynamic range. So it is named second and hedged:
    /// reaching here with the priority still on means the clearing write was refused too, which is
    /// the same ISO floor one property along, and `dRangePriorityRefusalHint` covers that case.
    var dynamicRangeRefusalHint: String? {
        guard rejected.contains(where: { $0.code == FujiPTP.PresetProp.dynamicRange.rawValue }) else { return nil }
        return "The camera decides this one, and it's almost always the ISO: DR200 and DR400 need "
             + "that slot's own ISO at 2× and 4× the camera's base, and the app can't read it. "
             + "Check the bank in the IQ menu — its ISO, and D-Range Priority, which locks Dynamic "
             + "Range out entirely while it's on."
    }

    /// Why a refused **D-Range Priority** was refused — the one write this app makes on the user's
    /// behalf rather than at their request, so a failure owes them an explanation more than most.
    ///
    /// `D191` is ISO-gated like `D190`, and harder: at base ISO the camera refuses *every* write to
    /// it, including one of the value it already holds (X-T50 fw 1.32, 2026-09-17). A bank can sit
    /// there holding the priority on — the stored value and the live state come apart, which is why
    /// the camera greys the menu item out rather than clearing it — and then it cannot be turned off
    /// over USB at all. That is exactly the case the push volunteers to handle when a recipe sets a
    /// dynamic range, so it is exactly the case that needs saying out loud when it fails.
    var dRangePriorityRefusalHint: String? {
        guard rejected.contains(where: { $0.code == FujiPTP.PresetProp.dRangePriority.rawValue })
        else { return nil }
        return "D-Range Priority is gated by that slot's own ISO, and at the camera's base ISO it "
             + "refuses every write — even one that changes nothing. Raise the bank's ISO if you "
             + "want this recipe's priority, or set it in the camera's IQ menu."
    }

    /// Why a refused **Clarity** was refused. `D1A2` is refused for every value, the one it already
    /// holds included, while the *bank's* image format is HEIF, and accepted on a JPEG bank in the
    /// same session; the format is a bank setting outside the 23 bank properties, so the push cannot see
    /// it coming. Measured on an X-T50 (fw 1.32, 2026-10-15) and published for the GFX100RF —
    /// zgrimz/fujifilm-ptp-reference `docs/04-custom-slots.md#why-a-write-is-refused`.
    var clarityRefusalHint: String? {
        guard rejected.contains(where: { $0.code == FujiPTP.PresetProp.clarity.rawValue }) else { return nil }
        return "Clarity is refused while that bank's image format is HEIF: the camera doesn't offer "
             + "Clarity for HEIF, and the format is a bank setting the app can't read. Set the bank's "
             + "IMAGE QUALITY to a JPEG option if you want this recipe's Clarity, or leave it."
    }

    /// Why a refused **neutral toning** was refused. A GFX100RF refuses a write of `0` to either
    /// Monochromatic Color axis even on a monochrome simulation, where an X-T50 and an X-H2 accept
    /// it (zgrimz/fujifilm-ptp-reference `docs/03-encodings.md#polarity-and-use`). The app writes
    /// explicit zeros so a neutral recipe clears a previous tint, which on such a body costs two
    /// refusals that change nothing the user chose. Only for a zero: a refused tint is a different
    /// question (a colour simulation, or Sepia).
    var toningZeroRefusalHint: String? {
        let axes: Set<UInt16> = [FujiPTP.PresetProp.monochromaticWC.rawValue,
                                 FujiPTP.PresetProp.monochromaticMG.rawValue]
        guard rejected.contains(where: { axes.contains($0.code) && $0.wrote == FujiEncoding.packI16(0) })
        else { return nil }
        return "This body refuses a Monochromatic Color of 0, which is how the recipe says \"no tint\". "
             + "The bank keeps the toning it had; check it in the IQ menu if the slot was tinted before."
    }

    /// Fields dropped before the push because this model has no such control (`code == 0`).
    var unsupportedOnModel: [FieldResult] {
        recipeFields.filter { $0.code == 0 }
    }

    /// Fields the push never reached.
    var notAttempted: [FieldResult] {
        recipeFields.filter { $0.outcome == .notAttempted }
    }

    /// Every recipe field whose read-back didn't match what we wrote, with the raw values, so a
    /// verification failure is diagnosable instead of just "something didn't stick".
    var mismatches: [ReadBackMismatch] {
        recipeFields.compactMap { f in
            guard case .mismatched(let wrote, let read) = f.outcome else { return nil }
            return ReadBackMismatch(code: f.code, field: f.field, wrote: wrote, read: read)
        }
    }

    /// Plain-language statement of what the slot now holds, for the results screen.
    var plainLanguageState: String {
        switch outcome {
        case .applied:
            return "C\(slot) holds your recipe."
        case .partiallyApplied:
            // `unsupportedOnModel` counts too: those rows are recipe fields the body hasn't got
            // (`code == 0`), excluded from `rejected` because the camera never saw them, but they
            // stop `outcome(for:)` seeing every field written and can be the sole reason a push
            // lands here.
            let bad = rejected.count + unsupportedOnModel.count + notAttempted.count
                    + mismatches.count
            return "C\(slot) holds a mix of its old contents and your new recipe — \(bad) "
                 + "\(bad == 1 ? "setting" : "settings") didn't make it."
        case .notWritten:
            return "C\(slot) is unchanged."
        case .unknown:
            return "C\(slot) may have changed, but the operation could not be verified — "
                 + "its contents are unconfirmed."
        }
    }
}

/// A slot whose film simulation no longer matches what the last applied push wrote to it.
///
/// Five X-T50 slots have reverted to PROVIA between sessions after every push wrote the right value
/// and byte-verified it. A push's own refresh runs before such a change, so only a re-read compared
/// against the last push catches it. The comparison is cheap: both values are already in the report.
struct FilmSimulationDrift: Identifiable, Equatable {
    let slot: Int
    /// What the push wrote, decoded. Nil if the byte no longer maps to a known simulation.
    let wrote: FilmSimulation?
    /// What the slot holds now, decoded.
    let holds: FilmSimulation?
    /// When that push ran.
    let pushedAt: Date

    var id: Int { slot }

    var summary: String {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short
        return "C\(slot) was written as \(wrote?.displayName ?? "an unknown simulation") at \(f.string(from: pushedAt)) and now holds \(holds?.displayName ?? "an unknown simulation")"
    }
}

/// One field that failed post-write verification, with the bytes involved.
struct ReadBackMismatch: Equatable {
    let code: UInt16
    let field: String
    let wrote: Data
    let read: Data?

    private static func hex(_ d: Data?) -> String { d.map { "0x" + PTPHex.bytes($0) } ?? "nothing" }

    /// e.g. `Grain Effect (D195): wrote 0x0400, camera has 0x0200`
    var detail: String {
        String(format: "%@ (%@): wrote %@, camera has %@",
               field, PTPHex.propertyLabel(code), Self.hex(wrote), Self.hex(read))
    }
}

/// Low-level transport to a camera at the **PTP device-property** level — exactly the operations
/// `requestSendPTPCommand` exposes. Two implementations: `ImageCaptureTransport` (real hardware) and
/// `MockCameraTransport` (in-memory demo). Slot orchestration (select → read/write properties →
/// verify) lives in `SlotReader` and `SlotWriter`, so it's identical for both.
protocol CameraTransport: AnyObject {
    var productName: String { get }
    var firmwareVersion: String? { get }
    /// USB vendor/product ids from enumeration, when the transport has them (real hardware only).
    var usbIdentity: USBIdentity? { get }

    func open() async throws
    func close() async

    /// `GetDeviceInfo` — the raw DeviceInfo dataset (PIMA 15740 §5.5.1), or nil when the transport
    /// has no way to ask. Parsed by `FujiPTP.parseDeviceInfo`; captured once per connect.
    func deviceInfo() async throws -> Data?

    /// Attach a trace recorder — or detach with nil — so the compatibility report can carry a
    /// bounded record of the connect/probe transactions. Transports that can't trace ignore it.
    func attachTrace(_ recorder: PTPTraceRecorder?) async

    /// `GetDevicePropValue` — the property's value bytes, or nil if unsupported/empty.
    func readProperty(_ code: UInt16) async throws -> Data?

    /// `SetDevicePropValue` — write the value bytes for a property.
    func writeProperty(_ code: UInt16, _ bytes: Data) async throws

    /// `GetDevicePropDesc` — the raw descriptor dataset for a property (data type, writability, and
    /// the values the camera will accept), or nil if it returns nothing. Diagnostics only: it backs
    /// the property report, and no read/import/push path depends on it.
    func readPropertyDescriptor(_ code: UInt16) async throws -> Data?
}

extension CameraTransport {
    var usbIdentity: USBIdentity? { nil }
    func deviceInfo() async throws -> Data? { nil }
    func attachTrace(_ recorder: PTPTraceRecorder?) async {}
    /// Transports that can't ask (or don't need to) report "no descriptor" rather than failing.
    func readPropertyDescriptor(_ code: UInt16) async throws -> Data? { nil }
}

/// A transport that additionally supports the **object-transfer** PTP operations needed to drive
/// in-camera RAW conversion (upload a RAF, then retrieve the produced JPEG). The conversion
/// orchestration in `RawConversionService` requires a transport conforming to this; the
/// property-level reads/writes (D185 profile, D183 trigger) ride on the base `CameraTransport`.
///
/// Both implementations conform: `MockCameraTransport` (simulated cook) and `ImageCaptureTransport`
/// (real `requestSendPTPCommand`).
protocol RawConversionTransport: CameraTransport {
    /// Upload one object (SendObjectInfo + SendObject), e.g. the RAF to be converted.
    func sendObject(_ data: Data, filename: String) async throws

    /// `GetObjectHandles` — current object handles on the camera (used to spot the new JPEG).
    func getObjectHandles() async throws -> [UInt32]

    /// Object metadata used to validate a newly enumerated conversion candidate.
    func getObjectInfo(_ handle: UInt32) async throws -> FujiPTP.ObjectInfo

    /// `GetObject` — the full bytes of one object handle (the converted JPEG).
    func getObject(_ handle: UInt32) async throws -> Data

    /// `DeleteObject` — remove a temporary object handle (cleanup after retrieval).
    func deleteObject(_ handle: UInt32) async throws
}
