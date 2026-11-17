import Foundation

/// An in-memory "Demo Camera" that emulates the real Fuji PTP property model: a current slot
/// selector (`0xD18C`), per-slot preset properties (`0xD18E…0xD1A4`), and a name (`0xD18D`).
///
/// Because it speaks the same property-level `CameraTransport` contract and stores values produced
/// by the real `FujiPresetCodec`, the full connect → read → import → push → read-back-verify flow
/// runs in the Simulator with no hardware **and exercises the real encode/decode path**, so the
/// lossless round-trip can be demonstrated end to end.
actor MockCameraTransport: CameraTransport {
    nonisolated let productName: String
    nonisolated let firmwareVersion: String?
    /// See `MockCameraFaults.presentsAsHardware`.
    nonisolated let presentsAsHardware: Bool

    private var slots: [Int: [UInt16: Data]] = [:]
    private var names: [Int: String] = [:]
    /// Readable so a test can assert the read-only property report sweep used the slot the camera
    /// already had rather than selecting one.
    private(set) var currentSlot = 1
    private var isOpen = false

    /// Injected failure modes. Default-constructed this is a camera with no faults, which is what
    /// the Demo Camera uses; tests and `CameraView`'s faulted demo pass a populated one.
    private let faults: MockCameraFaults
    /// One-shot faults armed after a successful scan, for failures at a mutation's own preflight.
    /// Permanent read faults alone cannot distinguish a clean backup from a later failed reading.
    enum QueuedRead: Sendable {
        case normal
        case response(UInt16)
        case value(Data?)
    }
    private var queuedReads: [UInt16: [QueuedRead]] = [:]
    enum QueuedObjectHandles: Sendable { case normal; case data(Data?) }
    private var queuedObjectHandles: [QueuedObjectHandles] = []
    private(set) var conversionTriggerCount = 0
    private(set) var deletedObjectHandles: [UInt32] = []
    private var objectFormats: [UInt32: UInt16] = [:]
    private var objectInfoOverrides: [UInt32: FujiPTP.ObjectInfo] = [:]

    func overrideObjectInfo(_ info: FujiPTP.ObjectInfo, for handle: UInt32) {
        objectInfoOverrides[handle] = info
    }

    func queueObjectHandles(_ result: QueuedObjectHandles) { queuedObjectHandles.append(result) }

    func storeObject(_ data: Data, format: UInt16 = 0x3801) -> UInt32 {
        let handle = nextConvHandle
        nextConvHandle &+= 1
        convObjects[handle] = data
        objectFormats[handle] = format
        return handle
    }
    private var ignoredNextWrites: Set<UInt16> = []

    func queueRead(_ result: QueuedRead, for code: UInt16) {
        queuedReads[code, default: []].append(result)
    }

    func ignoreNextWrite(to code: UInt16) { ignoredNextWrites.insert(code) }

    /// One-shot: the next write to `code` stops before it reaches the camera, calls `onHeld`, and
    /// waits there until `releaseHeldWrite()`. Holds an operation part-way so a test can say what
    /// may start while it is in flight; racing two tasks cannot, since the first may finish first.
    func holdNextWrite(to code: UInt16, onHeld: @escaping @Sendable () -> Void) {
        writeToHold = (code, onHeld)
    }

    /// Lets the held write through, or disarms a hold that has not been reached yet.
    func releaseHeldWrite() {
        writeToHold = nil
        heldWrite?.resume()
        heldWrite = nil
    }
    private var writeToHold: (code: UInt16, onHeld: @Sendable () -> Void)?
    private var heldWrite: CheckedContinuation<Void, Never>?

    /// One-shot: the next `open()` stops before the session opens, calls `onHeld`, and waits there
    /// until `releaseHeldOpen()`, ignoring cancellation the way an ImageCaptureCore session open
    /// does. Holds a connect inside its open so a test can cancel it there.
    func holdNextOpen(onHeld: @escaping @Sendable () -> Void) {
        openHold = onHeld
    }

    /// Lets the held open through, or disarms a hold that has not been reached yet.
    func releaseHeldOpen() {
        openHold = nil
        heldOpen?.resume()
        heldOpen = nil
    }
    private var openHold: (@Sendable () -> Void)?
    private var heldOpen: CheckedContinuation<Void, Never>?

    /// Preset-property write *attempts* this session, for `rejectWriteAtIndex` and
    /// `dropSessionAfterWrites`. Attempts rather than successes, so a rejected property still
    /// advances the index — otherwise two faults set together would silently renumber each other.
    /// Slot-select and name writes don't count: those aren't the property loop.
    private var presetWriteCount = 0
    /// Set once `dropSessionAfterWrites` fires. Distinct from `isOpen`, which the app closed
    /// deliberately: this is the cable coming out mid-operation, and it reports as
    /// `disconnectedDuringOperation` rather than a clean session failure.
    private var sessionDropped = false
    /// Every `writeProperty` call this session — slot selects and names included. Lets a test state
    /// the one thing the unrecognized-body path must guarantee: nothing was written, not even D18C.
    private(set) var totalWriteCount = 0
    /// Every operation the app asked this transport for, answered, refused or failed: each one
    /// starts at `requireSession`, which counts it. Lets a test state that an operation the gate
    /// refused sent the camera nothing at all.
    private(set) var transactionCount = 0
    /// Bounded transaction trace for the compatibility report; nil when nobody is listening.
    private var trace: PTPTraceRecorder?

    // RAW-conversion ("Kitchen") demo state. The mock keeps a 0xD185 profile blob the cook flow
    // reads/patches/writes, then "converts" by rendering a JPEG that reflects the applied recipe.
    private var convProfile = FujiRawConvProfile.demoBaseProfile()
    private var convObjects: [UInt32: Data] = [:]
    private var nextConvHandle: UInt32 = 0x0001_0001
    private var lastUploadedRAF = "image.RAF"
    private var hasUploaded = false

    init(faults: MockCameraFaults = MockCameraFaults()) {
        self.faults = faults
        self.productName = faults.productName
        // Like hardware: the transport itself does not know the firmware. It reaches the app only
        // through `GetDeviceInfo`'s `deviceVersion`, which `deviceInfo(for:)` fills from the faults.
        self.firmwareVersion = nil
        self.presentsAsHardware = faults.presentsAsHardware
        (slots, names) = faults.startsWithEmptySlots ? ([:], [:]) : Self.seededSlots()
    }

    /// The two preprogrammed demo slots. Built by a `static` (so the actor's nonisolated `init` can
    /// call it without hopping onto the actor) that returns the state for `init` to assign directly.
    private static func seededSlots() -> (slots: [Int: [UInt16: Data]], names: [Int: String]) {
        let model = CameraModelRegistry.shared.demoModel
        var slots: [Int: [UInt16: Data]] = [:]
        var names: [Int: String] = [:]

        func store(_ slot: Int, _ name: String, _ settings: RecipeSettings) {
            var props: [UInt16: Data] = [:]
            // `.empty`: these slots are being established from nothing, which is the one case
            // that legitimately takes the codec's seed values for the housekeeping properties.
            for (code, bytes) in FujiPresetCodec.encode(settings, model: model, slot: .empty) { props[code] = bytes }
            // Real readable banks retain inactive values. The recipe encoder intentionally omits
            // them, but a camera snapshot must still supply their originals before a later change.
            for code in [FujiPTP.PresetProp.monochromaticWC.rawValue,
                         FujiPTP.PresetProp.monochromaticMG.rawValue, FujiPTP.PresetProp.color.rawValue] {
                if props[code] == nil { props[code] = FujiEncoding.packI16(0) }
            }
            if props[FujiPTP.PresetProp.colorTemp.rawValue] == nil {
                props[FujiPTP.PresetProp.colorTemp.rawValue] = FujiEncoding.packU16(5000)
            }
            slots[slot] = props
            names[slot] = name
        }

        store(1, "Sunny 16", RecipeSettings(
            filmSimulation: .classicChrome,
            grain: GrainEffect(strength: .weak, size: .small),
            colorChromeEffect: .strong, colorChromeFXBlue: .weak,
            whiteBalance: WhiteBalance(mode: .daylight, shiftRed: 2, shiftBlue: -3, kelvin: nil),
            dynamicRange: .dr400,
            highlightTone: -0.5, shadowTone: 1.0, color: 2, sharpness: -1, highISONR: -3, clarity: 1))

        store(2, "ACROS Street", RecipeSettings(
            filmSimulation: .acrosR, monochromaticColorWC: 2,
            grain: GrainEffect(strength: .strong, size: .large),
            whiteBalance: WhiteBalance(mode: .auto, shiftRed: 0, shiftBlue: 0, kelvin: nil),
            dynamicRange: .dr200,
            highlightTone: 1.0, shadowTone: 2.0, sharpness: 1, highISONR: -4, clarity: 3))
        // Every other slot is left unprogrammed and reads back as empty.

        return (slots, names)
    }

    /// What the slots held when the session was last opened, kept only for
    /// `revertsWritesOnReopen`. This is the state a body with that fault comes back up in.
    private var slotsAtLastOpen: ([Int: [UInt16: Data]], [Int: String])?

    func open() async throws {
        if let onHeld = openHold {
            openHold = nil
            await withCheckedContinuation { continuation in
                heldOpen = continuation
                onHeld()
            }
        }
        try await settle(250_000_000)
        // Restoring *before* the snapshot, so a second power cycle reverts to the same original
        // rather than to whatever the first one left.
        if faults.revertsWritesOnReopen, let (storedSlots, storedNames) = slotsAtLastOpen {
            slots = storedSlots
            names = storedNames
        }
        slotsAtLastOpen = (slots, names)
        isOpen = true
        sessionDropped = false
        presetWriteCount = 0
    }
    func close() async { isOpen = false }

    // MARK: Traced entry points

    func attachTrace(_ recorder: PTPTraceRecorder?) async { trace = recorder }

    func readProperty(_ code: UInt16) async throws -> Data? {
        do {
            let data = try await readPropertyUntraced(code)
            record(.getDevicePropValue, [UInt32(code)], inData: data, response: FujiPTP.responseOK)
            return data
        } catch { recordFailure(.getDevicePropValue, [UInt32(code)], error); throw error }
    }

    func writeProperty(_ code: UInt16, _ bytes: Data) async throws {
        do {
            try await writePropertyUntraced(code, bytes)
            record(.setDevicePropValue, [UInt32(code)], out: bytes, inData: nil, response: FujiPTP.responseOK)
        } catch { recordFailure(.setDevicePropValue, [UInt32(code)], error, out: bytes); throw error }
    }

    func readPropertyDescriptor(_ code: UInt16) async throws -> Data? {
        do {
            let data = try await readPropertyDescriptorUntraced(code)
            record(.getDevicePropDesc, [UInt32(code)], inData: data, response: FujiPTP.responseOK)
            return data
        } catch { recordFailure(.getDevicePropDesc, [UInt32(code)], error); throw error }
    }

    /// `GetDeviceInfo`, answered from the faults: the product name and firmware the transport was
    /// built with, the operations the mock implements, and every property code the mock serves
    /// minus the ones a fault declares unsupported — so a body "missing" a property is missing it
    /// here too, and the report's two views of that fact agree.
    func deviceInfo() async throws -> Data? {
        try requireSession()
        try await settle(30_000_000)
        if faults.refusesDeviceInfo {
            let refused = CameraError.ptpError(code: 0x2005)
            recordFailure(.getDeviceInfo, [], refused)
            throw refused
        }
        let data = FujiPTP.encodeDeviceInfo(Self.deviceInfo(for: faults))
        record(.getDeviceInfo, [], inData: data, response: FujiPTP.responseOK)
        return data
    }

    static func deviceInfo(for faults: MockCameraFaults) -> FujiPTP.DeviceInfo {
        var info = FujiPTP.DeviceInfo()
        info.vendorExtensionID = 0x0000_0006
        info.vendorExtensionVersion = 100
        info.vendorExtensionDesc = "fujifilm.com: 1.0; demo"
        info.operationsSupported = [0x1001, 0x1002, 0x1003, 0x1007, 0x1008, 0x1009, 0x100B,
                                    0x1014, 0x1015, 0x1016, 0x900C, 0x900D]
        let controls: [UInt16] = [FujiPTP.Prop.slotSelector, FujiPTP.Prop.presetName,
                                  FujiPTP.Prop.startRawConversion, FujiPTP.Prop.rawConvProfile]
        info.devicePropertiesSupported = (controls + FujiPTP.PresetProp.allCases.map(\.rawValue))
            .filter { !faults.unsupportedReadCodes.contains($0) }
        info.captureFormats = [FujiPTP.rafObjectFormat]
        info.imageFormats = [0x3801, FujiPTP.rafObjectFormat]
        info.manufacturer = "FUJIFILM"
        info.model = faults.productName
        info.deviceVersion = faults.firmwareVersion ?? ""
        info.serialNumber = "DEMO0000001"
        return info
    }

    private func record(_ op: FujiPTP.Operation, _ params: [UInt32], out: Data? = nil,
                        inData: Data?, response: UInt16) {
        trace?.record(operation: op.rawValue, parameters: params, outData: out,
                      inData: inData, response: response, error: nil, durationMs: 0)
    }

    private func recordFailure(_ op: FujiPTP.Operation, _ params: [UInt32], _ error: Error, out: Data? = nil) {
        if case CameraError.ptpError(let code) = error {
            trace?.record(operation: op.rawValue, parameters: params, outData: out,
                          inData: nil, response: code, error: nil, durationMs: 0)
        } else {
            trace?.record(operation: op.rawValue, parameters: params, outData: out,
                          inData: nil, response: nil, error: error.diagnosticReason, durationMs: 0)
        }
    }

    // MARK: Fault plumbing

    /// Simulated USB latency, skipped entirely when `faults.isInstant` — a test shouldn't pay
    /// 250ms to open a session it opens a hundred times.
    private func settle(_ nanoseconds: UInt64) async throws {
        guard !faults.isInstant else { return }
        try await Task.sleep(nanoseconds: nanoseconds)
    }

    /// Every operation starts here. The two failures are deliberately different errors: a session
    /// that was never opened is a programming mistake, and a session that dropped underneath a
    /// running operation is the cable coming out — which is what the push path has to survive.
    private func requireSession() throws {
        transactionCount += 1
        if sessionDropped { throw CameraError.disconnectedDuringOperation }
        guard isOpen else { throw CameraError.sessionFailed("session not open") }
    }

    private func readPropertyUntraced(_ code: UInt16) async throws -> Data? {
        try requireSession()
        if var pending = queuedReads[code], !pending.isEmpty {
            let result = pending.removeFirst()
            queuedReads[code] = pending.isEmpty ? nil : pending
            switch result {
            case .normal: break
            case .response(let response): throw CameraError.ptpError(code: response)
            case .value(let data): return data
            }
        }
        if let response = faults.readResponseCodes[code] {
            throw CameraError.ptpError(code: response)
        }
        if faults.unsupportedReadCodes.contains(code) {
            throw CameraError.ptpError(code: FujiPTP.responseDevicePropNotSupported)
        }
        // OK with no data phase: succeeds, answers nothing, and the caller can't tell that from a
        // property the slot genuinely doesn't have.
        if faults.emptyReadCodes.contains(code) { return nil }
        // Ahead of the switch, so an injected value wins over whatever the slot holds: this is the
        // seam for encodings the app doesn't understand, and the slot can only hold ones it does.
        if let injected = faults.rawReadValues[code] { return injected }
        try await settle(20_000_000)
        switch code {
        case FujiPTP.Prop.slotSelector:
            return FujiEncoding.packU16(currentSlot)
        case FujiPTP.Prop.presetName:
            // An unnamed or emptied bank answers the count and the NUL, as the X-T50 does (fw 1.31 in
            // a published log, zgrimz/fujifilm-ptp-reference `docs/07-cameras.md#bank-behavior`; fw 1.32
            // after an empty-name write, 2026-10-19), never the one-byte form.
            guard let name = names[currentSlot], !name.isEmpty else { return Data([1, 0, 0]) }
            return FujiEncoding.packPTPString(name)
        case FujiPTP.Prop.rawConvProfile:
            // A body describes its conversion settings only once it has a RAF to describe.
            if faults.profileNeedsUpload, !hasUploaded {
                throw CameraError.ptpError(code: 0x2002)
            }
            return convProfile
        default:
            return slots[currentSlot]?[code]
        }
    }

    /// What a slot physically holds, bypassing every read fault.
    ///
    /// `readProperty` is the only other way in, and the faults that matter most to the push path
    /// are the ones that make reads lie — `emptyReadCodes` and `rawReadValues`. Asserting through
    /// them would make the assertion lie in exactly the same direction as the bug.
    func storedProperty(_ code: UInt16, slot: Int) -> Data? { slots[slot]?[code] }

    /// Synthesize the descriptor a *well-behaved* body would return for each preset property, built
    /// from the app's encodings (`FujiEncoding`). Running the property report against the Demo
    /// Camera therefore shows the report's shape — and, side by side with a real body's answer,
    /// where the app's assumed value set and the hardware's disagree.
    private func readPropertyDescriptorUntraced(_ code: UInt16) async throws -> Data? {
        try requireSession()
        try await settle(10_000_000)
        guard let prop = FujiPTP.PresetProp(rawValue: code) else { return nil }

        let current = slots[currentSlot]?[code].flatMap(FujiEncoding.decodeInt16)
        let form: FujiPTP.PropertyDescriptor.Form
        switch prop {
        case .filmSimulation:
            form = .enumeration(FujiEncoding.filmSimToByte.values.sorted())
        case .grain:
            form = .enumeration([1, 2, 3, 4, 5])   // the WRITE set; reads report Off as 6/7
        case .colorChrome, .colorChromeFXBlue, .smoothSkin:
            form = .enumeration([1, 2, 3])
        case .dynamicRange:
            // −1 (0xFFFF) is DR Auto, not a percentage — X-T50 fw 1.32, measured 2026-09-07.
            form = .enumeration([FujiEncoding.drAutoSlotValue, 100, 200, 400])
        case .whiteBalance:
            form = .enumeration(FujiEncoding.wbModeToValue.values.sorted())
        case .highISONR:
            form = .enumeration(FujiEncoding.nrDecode.keys.map(Int.init).sorted())
        case .highlightTone, .shadowTone:
            form = .range(min: -20, max: 40, step: 5)
        case .color, .sharpness, .clarity:
            form = .range(min: -40, max: 40, step: 10)
        case .wbShiftR, .wbShiftB:
            form = .range(min: -9, max: 9, step: 1)
        case .colorTemp:
            form = .range(min: 2500, max: 10000, step: 10)
        default:
            form = .none
        }
        // WB modes, the NR lookup and D-Range Priority are bit patterns (0x8001, 0x8000…), so
        // they're UINT16 on the wire; everything else the app touches is a signed value.
        let signed = (prop != .highISONR && prop != .whiteBalance && prop != .dRangePriority)
        let desc = FujiPTP.PropertyDescriptor(code: code,
                                              dataType: signed ? 0x0003 : 0x0004,
                                              isWritable: true,
                                              factoryDefault: nil,
                                              current: current,
                                              form: form)
        return FujiPTP.encodePropertyDescriptor(desc)
    }

    private func writePropertyUntraced(_ code: UInt16, _ bytes: Data) async throws {
        try requireSession()
        if let hold = writeToHold, hold.code == code {
            writeToHold = nil
            await withCheckedContinuation { heldWrite = $0; hold.onHeld() }
        }
        totalWriteCount += 1
        if let response = faults.writeResponseCodes[code] {
            throw CameraError.ptpError(code: response)
        }
        if faults.unsupportedWriteCodes.contains(code) {
            throw CameraError.ptpError(code: FujiPTP.responseDevicePropNotSupported)
        }
        if faults.invalidValueWriteCodes.contains(code) {
            throw CameraError.ptpError(code: FujiPTP.responseInvalidDevicePropValue)
        }
        // Count and gate *before* the write lands, so a rejected property is one the camera never
        // took — which is what distinguishes "rejected" from "written" in the outcome table.
        if FujiPTP.PresetProp(rawValue: code) != nil {
            presetWriteCount += 1
            if let n = faults.rejectWriteAtIndex, presetWriteCount == n {
                throw CameraError.ptpError(code: FujiPTP.responseInvalidDevicePropValue)
            }
        }
        try await settle(20_000_000)
        // Answered OK, changed nothing — the write returns normally and the switch below never runs.
        if ignoredNextWrites.remove(code) != nil || faults.silentlyIgnoredWriteCodes.contains(code) { return }
        if faults.ignoresOneByteNameWrites, code == FujiPTP.Prop.presetName, bytes.count == 1 { return }
        defer {
            // The drop happens *after* a successful write: those bytes are on the camera, and only
            // the next operation fails. A push that ends this way has changed the slot and cannot
            // prove it: `SlotOutcome.unknown`.
            if let n = faults.dropSessionAfterWrites, presetWriteCount >= n { sessionDropped = true }
        }
        switch code {
        case FujiPTP.Prop.slotSelector:
            let requested = Int(FujiEncoding.decodeUInt16(bytes) ?? 1)
            if let maxSlot = faults.maxSelectableSlot, requested > maxSlot {
                // A body with fewer slots than the registry assumes rejects the value outright.
                throw CameraError.ptpError(code: FujiPTP.responseDevicePropNotSupported)
            }
            currentSlot = requested
        case FujiPTP.Prop.presetName:
            names[currentSlot] = FujiEncoding.parsePTPString(bytes)
        case FujiPTP.Prop.rawConvProfile:
            // Mirror a real body's read/write asymmetry: the host writes X RAW Studio's 629-byte form
            // (the profile zero-extended, carrying the *host* parameter count of 29), and the camera
            // goes on reporting its own shorter blob with its own count — cells from `canonicalBase`. So
            // strip only trailing zero padding, back to the length this camera reads, and restore
            // the camera-side count. Anything else is kept verbatim: the mock must preserve whatever
            // shape the profile actually has, or the simulator can't reproduce a layout regression.
            let extra = bytes.count - convProfile.count
            if extra > 0, bytes.suffix(extra).allSatisfy({ $0 == 0 }) {
                var kept = Data(bytes.prefix(convProfile.count))
                let cells = (kept.count - FujiRawConvProfile.canonicalBase) / FujiRawConvProfile.fieldSize
                kept.writeLE(UInt16(clamping: cells), at: 0)
                convProfile = kept
            } else {
                convProfile = bytes
            }
        case FujiPTP.Prop.startRawConversion:
            conversionTriggerCount += 1
            // Simulate the X-Processor developing the buffered RAF with the patched profile: decode
            // the recipe straight back out of the profile blob (exercising the real codec) and render
            // a representative JPEG, exposed as a new object handle for the cook flow to retrieve.
            let settings = FujiRawConvProfile.decode(convProfile)
            let jpeg = DemoCookRenderer.render(settings: settings, filename: lastUploadedRAF)
            convObjects[nextConvHandle] = jpeg
            objectFormats[nextConvHandle] = faults.conversionObjectFormat
            nextConvHandle &+= 1
            for extra in faults.extraObjectsOnConversion { _ = storeObject(extra) }
        case FujiPTP.PresetProp.grain.rawValue:
            // Emulate the X-T50's asymmetric D195 (see FujiEncoding): writes accept 1–5 only;
            // a write of 1 (Off) is normalized to the read-side 6/7, keeping the size the slot
            // last had; anything else is rejected with 0x201C.
            let value = Int(FujiEncoding.decodeUInt16(bytes) ?? 0)
            switch value {
            case 2...5:
                slots[currentSlot, default: [:]][code] = bytes
            case 1:
                let previous = slots[currentSlot]?[code].flatMap(FujiEncoding.decodeInt16) ?? 6
                let largeRemembered = previous == 4 || previous == 5 || previous == 7
                slots[currentSlot, default: [:]][code] = FujiEncoding.packU16(largeRemembered ? 7 : 6)
            default:
                throw CameraError.ptpError(code: FujiPTP.responseInvalidDevicePropValue)
            }
        default:
            slots[currentSlot, default: [:]][code] = bytes
            if faults.kelvinResetsShifts, code == FujiPTP.PresetProp.colorTemp.rawValue {
                slots[currentSlot, default: [:]][FujiPTP.PresetProp.wbShiftR.rawValue] = FujiEncoding.packI16(0)
                slots[currentSlot, default: [:]][FujiPTP.PresetProp.wbShiftB.rawValue] = FujiEncoding.packI16(0)
            }
        }
        if faults.lostWriteResponseCodes.contains(code) { throw CameraError.timeout }
    }
}

// MARK: - RawConversionTransport (simulated object transfer)

extension MockCameraTransport: RawConversionTransport {
    // Object transfers are traced here the way `ImageCaptureTransport` traces them on hardware —
    // without payloads — so a test can assert what a probe did and, more to the point, didn't do.
    func sendObject(_ data: Data, filename: String) async throws {
        try requireSession()
        if let code = faults.rejectsUpload {
            let error = CameraError.ptpError(code: code)
            recordFailure(.sendObjectInfo, [0, 0, 0], error)
            throw error
        }
        try await settle(60_000_000)   // pretend a RAF takes a beat to upload
        lastUploadedRAF = filename
        hasUploaded = true
        if faults.uploadCreatesObject {
            // The handle only — holding a 200 MB RAF in the mock buys nothing.
            convObjects[nextConvHandle] = Data()
            objectInfoOverrides[nextConvHandle] = FujiPTP.ObjectInfo(
                objectFormat: FujiPTP.rafObjectFormat, compressedSize: 0, filename: "FUP_FILE.dat")
            nextConvHandle += 1
        }
        record(.sendObjectInfo, [0, 0, 0], inData: nil, response: FujiPTP.responseOK)
        if faults.lostUploadResponse {
            recordFailure(.sendObject2, [], CameraError.timeout)
            throw CameraError.timeout
        }
        record(.sendObject2, [], inData: nil, response: FujiPTP.responseOK)
    }

    func getObjectHandles() async throws -> [UInt32] {
        try requireSession()
        if !queuedObjectHandles.isEmpty, case .data(let data) = queuedObjectHandles.removeFirst() {
            do {
                let handles = try FujiPTP.parseObjectHandles(data)
                record(.getObjectHandles, [0xFFFF_FFFF, 0, 0], inData: data, response: FujiPTP.responseOK)
                return handles
            } catch {
                recordFailure(.getObjectHandles, [0xFFFF_FFFF, 0, 0], error)
                throw error
            }
        }
        record(.getObjectHandles, [0xFFFF_FFFF, 0, 0], inData: nil, response: FujiPTP.responseOK)
        return Array(convObjects.keys).sorted()
    }

    func getObjectInfo(_ handle: UInt32) async throws -> FujiPTP.ObjectInfo {
        try requireSession()
        if let override = objectInfoOverrides[handle] { return override }
        guard let data = convObjects[handle] else { throw CameraError.ptpError(code: 0x2009) }
        record(.getObjectInfo, [handle], inData: nil, response: FujiPTP.responseOK)
        return FujiPTP.ObjectInfo(objectFormat: objectFormats[handle] ?? 0x3801,
                                  compressedSize: UInt32(data.count), filename: "converted.jpg")
    }

    func getObject(_ handle: UInt32) async throws -> Data {
        try requireSession()
        try await settle(40_000_000)
        guard let data = convObjects[handle] else {
            recordFailure(.getObject, [handle], CameraError.noOutputProduced)
            throw CameraError.noOutputProduced
        }
        record(.getObject, [handle], inData: nil, response: FujiPTP.responseOK)
        return faults.conversionDownloadOverride ?? data
    }

    func deleteObject(_ handle: UInt32) async throws {
        try requireSession()
        if let response = faults.deleteObjectResponse { throw CameraError.ptpError(code: response) }
        deletedObjectHandles.append(handle)
        convObjects[handle] = nil
        objectFormats[handle] = nil
        objectInfoOverrides[handle] = nil
        if faults.lostDeleteResponse {
            recordFailure(.deleteObject, [handle], CameraError.timeout)
            throw CameraError.timeout
        }
        record(.deleteObject, [handle], inData: nil, response: FujiPTP.responseOK)
    }
}
