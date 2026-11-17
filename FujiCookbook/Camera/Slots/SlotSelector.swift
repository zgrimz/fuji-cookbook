import Foundation

/// What a read of the slot selector (`0xD18C`) answered.
///
/// The answer the camera gives to this one read is what tells a bank-block body from one without:
/// a value is a selector, `0x200A` is the record's "not supported in this context"
/// (zgrimz/fujifilm-ptp-reference `docs/01-transport.md#response-codes`), and anything else is a
/// failure that says nothing about the block either way.
enum SelectorRead: Equatable {
    case notRead
    case value(Int)
    /// `0x200A DeviceProp Not Supported`.
    case unsupported
    /// Any other error, or an answer that isn't two bytes.
    case failed(String)

    /// The selected bank, when the read answered one.
    var value: Int? {
        if case .value(let bank) = self { return bank }
        return nil
    }

    /// For the compatibility report: `C1`, `unsupported (0x200A)`, `failed: <detail>`, `not read`.
    var reportLabel: String {
        switch self {
        case .notRead: return "not read"
        case .value(let bank): return "C\(bank)"
        case .unsupported: return "unsupported (0x200A)"
        case .failed(let detail): return "failed: \(detail)"
        }
    }
}

/// Reads and restores the camera's slot selector (0xD18C).
///
/// On the bodies measured the selector is a host-side cursor, not the bank the camera shoots with:
/// writing it changes nothing on the body, and a read answers whatever the last host left there —
/// kept across reconnects and the body's own bank changes on an X-T50, reset by a bank change on a
/// GFX100RF (zgrimz/fujifilm-ptp-reference `docs/04-custom-slots.md`). The walk, the property
/// report and the grain probe put it back after selecting banks in turn, so the next host finds it
/// where it was; no other body has been checked. A push does not put it back.
@MainActor
struct SlotSelector {
    let transport: CameraTransport
    let reports: CompatibilityReportRecorder

    /// The selector as the camera reports it. Touches nothing but the transport: `SlotReader`
    /// files the result into the report in a statement of its own, and a note written from in here
    /// would open a second report access inside the first.
    func read() async -> SelectorRead {
        do {
            return try await readUnlessSessionEnds()
        } catch {
            return .failed(error.cameraLogDescription)
        }
    }

    /// `read()`, except that an error that ends the session (`CameraError.endsSession`) is thrown
    /// rather than filed as `.failed`: the check after a select, where a failed read would otherwise
    /// count as a select the camera ignored.
    func readUnlessSessionEnds() async throws -> SelectorRead {
        do {
            guard let bytes = try await transport.readProperty(FujiPTP.Prop.slotSelector), bytes.count == 2,
                  let bank = FujiEncoding.decodeUInt16(bytes) else {
                return .failed("the selector answered no two-byte value")
            }
            return .value(Int(bank))
        } catch CameraError.ptpError(let code) where code == FujiPTP.responseDevicePropNotSupported {
            return .unsupported
        } catch let error where CameraError.endsSession(error) {
            throw error
        } catch {
            return .failed(error.cameraLogDescription)
        }
    }

    /// Put the selector back to `before`, verify it took, and say what happened. Never throws:
    /// a refused restore is a note in the report, not a failed connect — the reads that just
    /// happened are still good, and the camera is still connected.
    ///
    /// Returns what `SlotSummary.selectorRestored` should record; the caller decides whether to
    /// file it there (the walk does; the probes record their own note only).
    @discardableResult
    func restore(to before: Int?, after what: String) async -> Bool? {
        guard let before else {
            reports.noteOnce("\(what): could not read the selected bank beforehand, so it was not put back")
            CameraLog.info("Selector: not read before the \(what); not restored")
            return nil
        }
        // Already there — the walk on a one-slot body, or a probe of the bank the camera was on.
        if await read().value == before { return true }
        do {
            try await transport.writeProperty(FujiPTP.Prop.slotSelector, FujiEncoding.packU16(before))
        } catch {
            reports.noteOnce("\(what): putting the selected bank back to C\(before) was refused (\(error.cameraLogDescription)) — the camera is on a different bank than before")
            CameraLog.error("Selector: restore to C\(before) after the \(what) refused — \(error.cameraLogDescription)")
            return false
        }
        let now = await read().value
        guard now == before else {
            reports.noteOnce("\(what): selected bank written back as C\(before) but reads \(now.map { "C\($0)" } ?? "nothing") — the camera is on a different bank than before")
            CameraLog.error("Selector: restore to C\(before) after the \(what) did not take; reads \(now.map(String.init) ?? "nil")")
            return false
        }
        CameraLog.info("Selector: back on C\(before) after the \(what)")
        return true
    }

}
