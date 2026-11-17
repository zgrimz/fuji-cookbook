import Foundation

/// Reads what a body offers without writing anything to it, not even the slot selector.
@MainActor
struct ReadOnlyPropertySweep {
    let transport: CameraTransport
    let session: CameraSession
    let reports: CompatibilityReportRecorder

    /// The read-only path, for a body this app will not write to: either unrecognized, or a
    /// registry entry classified as having no USB slot protocol (`supportsSlotProtocol == false`).
    ///
    /// Read-only by construction. Nothing is written — not even the slot selector — so the sweep
    /// describes whichever slot the camera has selected. That promise is made to both callers.
    /// `GetDeviceInfo` has already run; this adds the value and, where the body allows, the
    /// descriptor of every property the app knows, recording each refusal as the code the body
    /// answered. Ends **connected**, with no slots: the tester can share the report, and nothing can
    /// be pushed.
    ///
    /// `model` is nil for an unrecognized body. When it is set, the sweep is also the app checking
    /// its own homework — see the confirmation at the end.
    ///
    /// Returns whether the sweep completed; the caller clears its slots on `true`.
    func run(model: CameraModel?) async -> Bool {
        session.setStatus(.working("Reading what this camera offers…"))
        var codes: [UInt16] = [FujiPTP.Prop.slotSelector, FujiPTP.Prop.presetName,
                               FujiPTP.Prop.startRawConversion, FujiPTP.Prop.rawConvProfile,
                               // Standard-PTP ISO, one transaction. Read in case it tracks the slot
                               // ISO that gates Dynamic Range writes; a refusal is recorded too,
                               // because it is the finding on a body that doesn't answer.
                               FujiPTP.Prop.exposureIndex]
        codes += FujiPTP.PresetProp.allCases.map(\.rawValue)
        var sweep = CameraCompatibilityReport.PropertySweep(slot: nil, readOnly: true)
        sweep.capturedAt = CameraCompatibilityReport.timestamp()
        sweep.evidenceID = UUID().uuidString
        var descriptorRefusals = 0
        do {
            for code in codes {
                var entry = CameraCompatibilityReport.PropertyProbeRecord(code: PTPHex.code(code),
                                                                          name: FujiPTP.propertyName(code))
                do {
                    let value = try await transport.readProperty(code)
                    let read = CameraCompatibilityReport.propertyRead(code: code, value: value, error: nil)
                    entry.value = read.value
                    entry.decoded = read.decoded
                    if code == FujiPTP.Prop.slotSelector, let value {
                        sweep.slot = FujiEncoding.decodeUInt16(value).map(Int.init)
                    }
                } catch let error where CameraError.endsSession(error) {
                    throw error
                } catch {
                    let read = CameraCompatibilityReport.propertyRead(code: code, value: nil, error: error)
                    entry.valueError = read.error
                    entry.valueResponseCode = read.responseCode
                    if case CameraError.ptpError(let c) = error, c == FujiPTP.responseDevicePropNotSupported {
                        reports.update { $0.noteUnsupported(code: code) }
                    }
                }
                do {
                    if let raw = try await transport.readPropertyDescriptor(code) {
                        if let d = FujiPTP.parsePropertyDescriptor(raw) {
                            entry.descriptor = CameraCompatibilityReport.descriptorRecord(d)
                        } else {
                            entry.descriptorError = "unparseable descriptor (\(raw.count) bytes)"
                        }
                    }
                } catch let error where CameraError.endsSession(error) {
                    throw error
                } catch {
                    entry.descriptorError = error.cameraLogDescription
                    descriptorRefusals += 1
                }
                sweep.entries.append(entry)
            }
        } catch {
            reports.update { $0.propertySweep = sweep }
            reports.note("sweep aborted: \(error.cameraLogDescription)")
            reports.persist()
            session.setStatus(.failed((error as? CameraError)?.errorDescription ?? error.localizedDescription))
            return false
        }
        if descriptorRefusals == codes.count {
            reports.note("GetDevicePropDesc refused for every property")
        }
        reports.update { $0.propertySweep = sweep }
        reports.update { $0.slots.selectorBeforeProbe = sweep.slot }
        reports.update { $0.touch() }
        reports.persist()
        let answered = sweep.entries.filter { $0.value != nil }.count
        let readSlotSelector = sweep.entries.contains { $0.code == PTPHex.code(FujiPTP.Prop.slotSelector) && $0.value != nil }
        // DeviceInfo's word first; the sweep's read of D18C when the body refused DeviceInfo.
        let advertised = reports.report?.deviceInfo?.devicePropertiesSupported.map(\.code) ?? []
        let hasSlotProtocol = advertised.isEmpty
            ? readSlotSelector
            : advertised.contains(PTPHex.code(FujiPTP.Prop.slotSelector)) && advertised.contains(PTPHex.code(FujiPTP.Prop.presetName))
        let subject = model?.id ?? "unrecognized body"
        CameraLog.info("Sweep: \(subject) answered \(answered) of \(codes.count) properties read-only; slot protocol \(hasSlotProtocol ? "present" : "absent"); selector at \(sweep.slot.map(String.init) ?? "?")")

        // The app checking its own homework. The registry said this body has no slot protocol; the
        // sweep just read `0xD18C` without writing it, so the evidence is already in hand and costs
        // nothing to act on.
        if let model, !model.supportsSlotProtocol {
            reports.note("\(model.id): the registry assumes \(model.slotCount) slots but classifies this body as having no USB slot protocol — no slot was selected and none were read")
            let selectorAnswered = sweep.entries.first { $0.code == PTPHex.code(FujiPTP.Prop.slotSelector) }
            let nameAnswered = sweep.entries.first { $0.code == PTPHex.code(FujiPTP.Prop.presetName) }
            let answeredAnyway = [selectorAnswered, nameAnswered].contains {
                $0?.value != nil || $0?.descriptor != nil
            }
            if answeredAnyway {
                // The finding most worth collecting: it would mean bodies are being blocked for
                // nothing. DeviceInfo is reported as corroboration only; its advertised list is not
                // exhaustive (see `DeviceInfoCapture`), so "absent from DeviceInfo" is never by
                // itself a reason to disable anything.
                let corroboration = advertised.isEmpty
                    ? "the body refused GetDeviceInfo"
                    : (hasSlotProtocol ? "and DeviceInfo advertises it too" : "though DeviceInfo does not advertise it")
                let held = selectorAnswered?.value.map { " (0xD18C holds \($0))" } ?? ""
                CameraLog.error("Sweep: UNEXPECTED — \(model.id) answered the slot protocol\(held) \(corroboration), though the registry classifies it as having none")
                reports.note("UNEXPECTED: \(model.id) answered the slot protocol\(held) \(corroboration). This body may expose custom slots after all, and is being blocked for nothing — please share this report.")
            } else {
                CameraLog.info("Sweep: \(model.id) refused 0xD18C and 0xD18D as the registry expects — no slot select was ever sent")
            }
            // Both paths: the notes above are added after this function's earlier `reports.persist()`,
            // so without this they'd live only in memory and be missing from the copy a crash leaves.
            reports.update { $0.touch() }
            reports.persist()
        }
        session.setStatus(.connected)
        return true
    }

}
