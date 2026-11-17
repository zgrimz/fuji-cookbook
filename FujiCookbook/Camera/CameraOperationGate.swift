import Foundation

/// `CameraOperationGate` refused an operation because another one held the camera. The refused
/// operation never started, so nothing was sent for it.
struct CameraBusy: Error, Equatable {
    /// The label of the operation that held the gate.
    let runningOperation: String
}

extension CameraBusy: LocalizedError {
    var errorDescription: String? {
        "The camera is busy with another operation (\(runningOperation)), so nothing was sent. Try again when it finishes."
    }
}

/// Lets one camera operation run at a time.
///
/// Every operation that changes camera state runs under it. The slot operations write
/// `FujiPTP.Prop.slotSelector` and then read or write the selected slot, so two of them
/// interleaved send one operation's writes into the other's slot: a property-report read
/// started during a grain probe moves the selector out from under a loop mid-way through writing
/// real values, and the probe's "restore" lands in a slot the user never chose. The UI's modal
/// sheets prevent most of that by accident; presentation is not a concurrency primitive, and this
/// is. A second operation is refused, not queued.
///
/// The gate belongs to the live session. An operation that outlives its session — a push still
/// unwinding after the cable was pulled while the camera reconnects — cannot reach the new transport
/// (the session epoch retires it), so it must not keep the new session's own slot read waiting
/// either: `retireRunningOperation` takes the gate back for the new session, and the retired
/// operation's exit then releases nothing.
@MainActor
final class CameraOperationGate {

    /// The label of the operation in flight, or nil.
    private(set) var runningOperation: String?

    /// Which claim on the gate is current. An operation releases the gate only while its own claim
    /// is still the current one.
    private var claim = 0

    /// Run `body` only if no other operation holds the gate; otherwise throw `CameraBusy` naming
    /// the operation that holds it, without running `body`. Not reentrant: a call from inside
    /// `body` is refused like any other.
    func run<T>(_ label: String, _ body: () async -> T) async throws(CameraBusy) -> T {
        if let inFlight = runningOperation {
            CameraLog.error("Camera: refused \(label) — \(inFlight) is still running")
            throw CameraBusy(runningOperation: inFlight)
        }
        claim &+= 1
        let mine = claim
        runningOperation = label
        defer { if claim == mine { runningOperation = nil } }
        return await body()
    }

    /// Take the gate back from an operation whose session is over. Called as a session begins, so
    /// the previous session's unfinished operation neither blocks the new session's slot read nor
    /// releases the gate out from under it.
    func retireRunningOperation() {
        guard let retired = runningOperation else { return }
        CameraLog.info("Camera: \(retired) belongs to a session that is over — the gate is free for the new one")
        claim &+= 1
        runningOperation = nil
    }
}
