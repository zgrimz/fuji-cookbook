import Foundation
import Observation

/// Opens and closes camera sessions and keeps them alive: the initial connect (demo or USB), an
/// idle keepalive, pausing while the app is in the background, and automatic recovery when a session
/// the user started drops. Connecting itself is always the user's action.
@MainActor
@Observable
final class CameraConnector {

    private let session: CameraSession
    private let reports: CompatibilityReportRecorder
    private let gate: CameraOperationGate
    private let slotReader: SlotReader
    private let slotWriter: SlotWriter
    private let conversion: RawConversionService
    private let makeDiscovery: @MainActor () -> CameraDiscovery
    /// Made on first use rather than in `init`: the app's discovery is the ImageCaptureCore browser,
    /// which is created on the first hardware connect, not at launch.
    @ObservationIgnored private lazy var discovery: CameraDiscovery = makeDiscovery()

    init(session: CameraSession, reports: CompatibilityReportRecorder, gate: CameraOperationGate,
         slotReader: SlotReader, slotWriter: SlotWriter, conversion: RawConversionService,
         discovery: @escaping @MainActor () -> CameraDiscovery) {
        self.session = session
        self.reports = reports
        self.gate = gate
        self.slotReader = slotReader
        self.slotWriter = slotWriter
        self.conversion = conversion
        self.makeDiscovery = discovery
    }

    private var status: CameraSession.Status {
        get { session.status }
        set { session.setStatus(newValue) }
    }
    private var connected: ConnectedCamera? {
        get { session.connected }
        set { session.setCamera(newValue) }
    }
    private var transport: CameraTransport? {
        get { session.transport }
        set { if let newValue { session.attach(newValue) } else { session.detach() } }
    }

    /// The physical device backing `transport`. Kept so the shared browser's removal signal and a
    /// recovery attempt can confirm they're talking about — or reconnecting to — the same body,
    /// rather than reacting to (or silently adopting) an unrelated camera.
    private var connectedDevice: (any DiscoveredCamera)?

    /// Background task that pings the camera while it's idle to keep the PTP session warm and to
    /// notice a session that died without a USB removal event. Runs only for a connect that passes
    /// `keepAlive: true` to `connect(using:identification:productName:firmwareVersion:keepAlive:)`.
    private var keepAlive: Task<Void, Never>?

    /// Auto-recovery after an *already-established* session drops (a cable jostle, a missed
    /// keepalive).
    private var recovery: Task<Void, Never>?
    /// Whether a dropped session is being re-established right now. The guided test's gate reads
    /// this rather than the status text.
    var isRecovering: Bool { recovery != nil }
    /// Timestamps of recent successful recoveries, so a cable that drops every thirty seconds stops
    /// being quietly papered over — repeated saves in a short window means the hardware needs
    /// attention, not another silent retry.
    private var recentRecoveries: [Date] = []
    /// Whether the loss being recovered from cut into a read, a write or a conversion. Recorded when
    /// the loss happens and kept through a recovery that backgrounding restarts; it decides how an
    /// unrecovered loss ends — see `endUnrecoveredLoss`.
    private var lossInterruptedOperation = false

    /// Until when a disconnect is the tester following instructions rather than a fault.
    ///
    /// The guided Camera Test asks for the cable out — to read the camera's own IQ menu, to take a
    /// photo — and for the camera to be switched off and on. Without this the connector cannot
    /// tell those from a failure: a deliberate power cycle runs the ordinary recovery, which can
    /// give up before the camera is back.
    ///
    /// A date rather than a `Bool`, because the cost of leaking the flag is asymmetric: a stuck
    /// `true` would hand a genuinely broken cable the patient schedule for the rest of the session.
    /// The window is twenty minutes, which is not how long a step takes but how long a tester might
    /// sit on the photo step before unplugging; leaving the flow is what actually disarms this, so
    /// the expiry only has to bound a leak.
    var removalExpectedUntil: Date?

    /// Arm or disarm the expectation. Set from the guided test's step changes; cleared when that
    /// flow goes away. Deliberately **not** cleared by `disconnect()`: `connect` calls it
    /// internally, which would disarm the expectation on the very reconnect it exists for.
    func expectRemoval(_ expected: Bool, for window: TimeInterval = 1200) {
        removalExpectedUntil = expected ? Date().addingTimeInterval(window) : nil
    }

    var removalIsExpected: Bool {
        guard let until = removalExpectedUntil else { return false }
        return until > Date()
    }

    /// Whether a session lost now had something in flight: a gated operation, or anything that
    /// publishes itself as busy — connect before its slot read takes the gate, and a push that
    /// holds the gate across a moment where its status reads `.connected`.
    ///
    /// Pure and internal, like `RecoveryPolicy.plan`, so the classification can be tested apart
    /// from the loss that triggers it.
    static func lossInterruptsOperation(status: CameraSession.Status, exclusiveOperation: String?) -> Bool {
        exclusiveOperation != nil || status.isBusy
    }

    /// True between the shared browser's suspend and resume signals (app backgrounding).
    /// ImageCaptureCore holds the PTP session open across a suspension — it only blocks traffic —
    /// so keepalive and recovery both pause here rather than treating the blocked traffic as loss.
    private var isSuspended = false

    /// Set once per session the first time a health probe is *refused* rather than answered, so the
    /// note that the session survived it is logged once instead of every five seconds.
    private var probeRefusalLogged = false

    // MARK: - Connect / disconnect

    /// The connect under way, from the request until it has run to its end: connected, failed,
    /// stopped by a disconnect, or cancelled.
    private var connectAttempt: ConnectAttempt?

    private enum ConnectAttempt {
        case running(Task<Void, Never>)
        /// Cancelled, and still finishing. The app can't interrupt ImageCaptureCore's session open,
        /// so a connect cancelled inside it runs on until the open returns, and then closes the
        /// session it got.
        ///
        /// The wait is short in practice. X-T50 fw 1.32 on an iPhone 14 Pro, 2026-09-06 to
        /// 2026-10-20: the app's logs record 61 session opens, with a median of 12 ms and a slowest
        /// of 53 ms, and every one returned.
        case cancelling(Task<Void, Never>)

        var task: Task<Void, Never> {
            switch self {
            case .running(let task), .cancelling(let task): return task
            }
        }
    }

    enum ConnectProgress: Equatable {
        case running
        /// Cancelled and still finishing; a new connect waits for it.
        case cancelling
    }

    /// Where the connect under way has got to, or nil when there is none.
    var connectProgress: ConnectProgress? {
        switch connectAttempt {
        case .running: return .running
        case .cancelling: return .cancelling
        case nil: return nil
        }
    }

    /// Whether a connect is under way, cancelled or not. The Connect rows stay disabled while it is.
    var isConnecting: Bool { connectAttempt != nil }

    /// Runs `connect`, unless a connect is already under way. One still running is joined: a second
    /// tap, or the Camera Test asking while the Camera tab's connect runs, is the same request, and
    /// a second connect beside the first would close the session the first is opening. One that
    /// was cancelled is waited out, so a new session open never overlaps one still in progress.
    private func connectExclusively(_ connect: @escaping @MainActor () async -> Void) async {
        while let attempt = connectAttempt {
            switch attempt {
            case .running(let task):
                CameraLog.info("Connect: a connect is already under way — waiting for it")
                await task.value
                return
            case .cancelling(let task):
                CameraLog.info("Connect: waiting for the cancelled connect to finish")
                await task.value
                endAttempt(task)
            }
        }
        let task = Task { await connect() }
        connectAttempt = .running(task)
        await task.value
        endAttempt(task)
    }

    /// Clears `task` once it has finished, if it is still the attempt. Called by whichever caller
    /// sees it end first.
    private func endAttempt(_ task: Task<Void, Never>) {
        if connectAttempt?.task == task { connectAttempt = nil }
    }

    /// Stops the connect under way and leaves the camera disconnected, with the same teardown as
    /// `disconnect()`. Does nothing when no connect is running.
    ///
    /// The connect stops at its next step. Inside a session open that is when the open returns, so
    /// until then `connectProgress` is `.cancelling` and a new connect waits for it.
    func cancelConnect() async {
        guard case .running(let task) = connectAttempt else { return }
        connectAttempt = .cancelling(task)
        task.cancel()
        CameraLog.info("Connect: cancelled")
        await disconnect()
    }

    /// The demo transport the last `connectDemo` used, kept so it can be reconnected to.
    ///
    /// The guided write pass asks for a power cycle and then checks whether the recipe survived it.
    /// On the demo that means disconnect and connect again — and a fresh `MockCameraTransport()`
    /// starts from the seeded slots every time, so the check would report every push as lost, on a
    /// transport that never lost anything. Holding the instance makes the demo behave like hardware
    /// here: what was written is still there unless a fault says otherwise.
    private(set) var lastDemoTransport: MockCameraTransport?

    func connectDemo() async {
        await connectDemo(using: lastDemoTransport ?? MockCameraTransport())
    }

    /// Connect a Demo Camera built with injected faults.
    ///
    /// Identification runs the way `connectHardware` does — the model is resolved from the
    /// transport's own product name — so a faulted name reproduces mis-identification end to end,
    /// including the case where a body resolves to the *wrong* model and then pushes cleanly. The
    /// default product name is the demo body's, which no registry entry matches, so it is mapped
    /// explicitly to `demoModel`.
    ///
    /// Takes the transport rather than the faults so a caller can keep a reference to it and ask
    /// the camera what it actually holds afterwards — which is the only way to tell a push that
    /// worked from one that merely reported success.
    func connectDemo(using transport: MockCameraTransport) async {
        await connectExclusively { await self.runDemoConnect(using: transport) }
    }

    private func runDemoConnect(using transport: MockCameraTransport) async {
        lastDemoTransport = transport
        let isDefaultDemoName = transport.productName == MockCameraFaults().productName
        let identification: ModelIdentification = isDefaultDemoName
            ? .exact(CameraModelRegistry.shared.demoModel)
            : CameraModelRegistry.shared.identify(productName: transport.productName)
        await connect(using: transport, identification: identification,
                      productName: transport.productName,
                      firmwareVersion: transport.firmwareVersion)
    }

    func connectHardware() async {
        await connectExclusively { await self.runHardwareConnect() }
    }

    private func runHardwareConnect() async {
        // During recovery `transport` is already nil, so the teardown below does not fire and
        // nothing else cancels the loop — leaving a recovery running that would, on its next
        // attempt, tear down the very session this tap is about to establish. The expected
        // schedule's longer wait widens that race.
        cancelRecovery()
        // A failed operation leaves the old transport (and its open PTP session) in place so the UI
        // can show the error. Reconnecting on top of that half-dead session makes the new open
        // intermittently fail — tear it down first.
        if transport != nil { await disconnect() }
        // A cancel during that teardown has already left the camera disconnected.
        guard !Task.isCancelled else { return }
        status = .connecting
        CameraLog.info("Connect: hardware connect requested")
        AppLog.flushNow()   // a connect is where a crash has followed within milliseconds; see `flushNow`
        bindBrowserCallbacks()
        do {
            let device = try await discovery.firstCamera()
            // The camera can appear just as Cancel is tapped.
            guard !Task.isCancelled else { return }
            connectedDevice = device
            let hwTransport = device.makeTransport()
            let identification = CameraModelRegistry.shared.identify(productName: hwTransport.productName)
            // An unrecognized body announces itself from `SlotReader.sweepReadOnly`, once DeviceInfo
            // can say whether it even has the slot protocol.
            await connect(using: hwTransport, identification: identification, productName: hwTransport.productName,
                          firmwareVersion: hwTransport.firmwareVersion, keepAlive: true)
        } catch {
            // Cancelling ends the wait for a camera; that is not a failure to find one.
            guard !Task.isCancelled else { return }
            let reason = (error as? CameraError)?.errorDescription ?? AppLog.bounded(error)
            CameraLog.error("Connect: discovery failed — \(reason)")
            reports.recordConnectionFailure(stage: "discovery", reason: reason,
                                    authorization: discovery.authorizationSummary)
            status = .failed((error as? CameraError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Wire the shared browser's lifecycle signals. Idempotent (just reassigns three closures) —
    /// called at the top of every hardware connect, which is also the earliest point the browser
    /// itself is started, so the very first connect in the app's life wires these up too.
    private func bindBrowserCallbacks() {
        let browser = discovery
        browser.onDeviceRemoved = { [weak self] removed in
            guard let self, let mine = self.connectedDevice, removed === mine else { return }
            self.handleConnectionLost(epoch: self.session.epoch.current, reason: "camera physically removed")
        }
        browser.onSuspend = { [weak self] in self?.suspendForBackground() }
        browser.onResume = { [weak self] in Task { await self?.resumeFromBackground() } }
    }

    private func connect(using transport: CameraTransport, identification: ModelIdentification,
                         productName: String? = nil, firmwareVersion: String? = nil,
                         keepAlive: Bool = false) async {
        let model = identification.model
        if self.transport != nil { await disconnect() }   // never stack a session on a stale one
        // Checked before the epoch advances: a cancel during that teardown has already retired
        // this connect's session, and a new epoch would bring it back.
        guard !Task.isCancelled else { return }
        let e = session.advanceEpoch()
        gate.retireRunningOperation()   // the outgoing session's unfinished operation must not hold this one's slot read
        status = .connecting
        if let hwTransport = transport as? ImageCaptureTransport {
            // Backstop for `bindBrowserCallbacks`' browser-level removal signal: this is the
            // per-device `ICCameraDeviceDelegate` callback, which can fire even if the browser-level
            // one is ever missed.
            hwTransport.onDisconnect = { [weak self] in
                self?.handleConnectionLost(epoch: e, reason: "transport reported device removal")
            }
        }
        do {
            try await transport.open()
            // A newer connect (or a disconnect) landed while this one was opening. This transport is
            // now live and unowned — close it, or its session leaks and the next open sees the
            // camera reporting a session already open.
            guard session.epoch.isCurrent(e, "connect completion") else { await transport.close(); return }

            self.transport = transport
            slotReader.discardProbedSlotCount()
            probeRefusalLogged = false

            let isDemo = (transport as? MockCameraTransport).map { !$0.presentsAsHardware } ?? false

            // A fresh report for this session, traced from here to the end of the slot read.
            reports.begin(CameraCompatibilityReport.begin(
                productName: productName ?? transport.productName,
                transport: isDemo ? "demo" : "usb",
                usb: transport.usbIdentity, modelID: identification.registryModel?.id,
                identification: identification.reportLabel,
                firmwareVersion: firmwareVersion ?? transport.firmwareVersion,
                verification: model?.verification.reportLabel,
                assumedSlotCount: model?.slotCount,
                documentedSlotCount: model?.documentedSlotCount))
            await transport.attachTrace(reports.trace)

            // GetDeviceInfo first, for every body: it is the only statement of which properties
            // exist before anything is read, and the firmware string when neither the caller nor
            // the transport has one.
            let deviceInfo = await DeviceInfoCapture(transport: transport, reports: reports).run(model: identification.model)
            guard session.epoch.isCurrent(e, "post-deviceInfo") else { return }
            let deviceFirmware = deviceInfo.flatMap { $0.deviceVersion.isEmpty ? nil : $0.deviceVersion }

            // Stop here rather than connect into a mode where nothing can work. Everything past
            // this point reads recipe properties the body has just said it doesn't have; without
            // the stop that is a body reported as unrecognized, a sweep answering none of its
            // properties, and a health probe refused every five seconds until recovery gives up —
            // three faces of one wrong menu setting, none of them naming it.
            if let deviceInfo, deviceInfo.looksLikeStorageOnlyMode {
                let advertised = deviceInfo.devicePropertiesSupported
                let detail = "DeviceInfo advertises \(advertised.count) propert\(advertised.count == 1 ? "y" : "ies") "
                    + "(\(advertised.map(PTPHex.code).joined(separator: " "))) and no camera-control block"
                CameraLog.error("Connect: the camera is in a storage USB mode — \(detail)")
                reports.note("wrong USB mode: \(detail). The body is in a card-reader/transfer mode, not USB RAW Conv./Backup Restore — no recipe property exists to read.")
                // Before the failure record, so the one transaction that diagnosed this — the
                // `GetDeviceInfo` itself — is in the trace the tester sends.
                reports.isTracing = false
                reports.persist()
                reports.recordConnectionFailure(stage: "usb-mode", reason: CameraError.wrongUSBMode.message,
                                        productName: productName ?? transport.productName,
                                        usb: transport.usbIdentity,
                                        identification: identification.reportLabel)
                await transport.attachTrace(nil)
                await transport.close()
                self.transport = nil
                // A failed recovery leaves `connected` standing while `transport` is nil, and this
                // connect never reached the line that replaces it — so clear it rather than show a
                // camera card next to the error card.
                self.connected = nil; slotReader.clearSlots()
                status = .failed(CameraError.wrongUSBMode.message)
                return
            }

            let firmware = firmwareVersion ?? transport.firmwareVersion ?? deviceFirmware
            let identification = Self.resolve(identification, productName: productName ?? transport.productName,
                                              deviceInfo: deviceInfo)
            if case .unlisted(let provisional) = identification {
                // The report began before `GetDeviceInfo` could name the body, as unknown.
                reports.update {
                    $0.camera.identification = identification.reportLabel
                    $0.camera.verification = provisional.verification.reportLabel
                    $0.slots.assumedSlotCount = provisional.slotCount
                }
                CameraLog.info("Identify: “\(productName ?? transport.productName)” matches no registry entry; named by GetDeviceInfo — reads allowed, writes decided by the slot read")
                reports.note("unlisted body: no registry entry; named by GetDeviceInfo (product name, serial, firmware); writes decided by the slot read")
            }
            // Decided twice: here from the identification and the registry alone, which settles a
            // trusted entry and a blocked one, and again once the slot read has answered for the
            // bodies the registry doesn't vouch for.
            self.connected = ConnectedCamera(
                productName: productName ?? transport.productName,
                firmwareVersion: firmware,
                identification: identification, isDemo: isDemo,
                writeAccess: WriteDecision.decide(identification: identification, observed: ObservedCapabilities(),
                                                  firmwareVersion: firmware,
                                                  serialHash: reports.report?.camera.serialHash))
            reports.update {
                $0.camera.firmwareVersion = connected?.firmwareVersion
                $0.camera.writeAccess = connected?.writeAccess.reportLabel
            }
            // Here rather than at `begin`, because the serial hash the carry-forward matches on
            // arrives with `GetDeviceInfo`.
            reports.carryHistoryForward()
            if case .heuristic(let guessed, _) = identification {
                CameraLog.info("Identify: “\(productName ?? transport.productName)” matched \(guessed.id) by name pattern only — reads allowed, writes decided by the slot read")
                reports.note("identified as \(guessed.id) by name pattern (heuristic); writes decided by the slot read")
            }
            status = .connected
            // Recovery reaches the slot read through here as well as a manual Connect, and the slot
            // walk is where a reconnect crash lands — so what led up to it is on disk.
            AppLog.flushNow()
            // Under the gate: the session already reads as connected, so a push or a probe tapped
            // while the walk is still selecting slots is refused rather than interleaved with it.
            // The gate was taken back for this session when the epoch advanced, and nothing can
            // claim it before this call, so a refusal here is a broken invariant — reported, not
            // ignored. A `false` with the gate free is the transport gone mid-connect, which the
            // loss handler owns.
            let read = await slotReader.requestRefresh()
            guard session.epoch.isCurrent(e, "post-refreshSlots") else { return }
            if read == nil, let holder = gate.runningOperation {
                CameraLog.error("Connect: the slot read was refused — \(holder) is still running")
                status = .failed("Another camera operation is still running. Disconnect and connect again.")
                return
            }
            // What the body answered, filed where the identification and the registry's word already
            // are, so the four stay four fields (`ObservedCapabilities`), and the decision made from
            // all three. Only now can a body the registry doesn't vouch for be granted.
            if let read, let camera = self.connected {
                let observed = camera.observing(read)
                self.connected = observed.deciding(WriteDecision.decide(
                    identification: observed.identification, observed: observed.observed,
                    firmwareVersion: observed.firmwareVersion, serialHash: reports.report?.camera.serialHash))
                slotReader.rememberCameraIfWritable()
                reports.update {
                    $0.record(slotRead: read, registryModel: camera.registryModel)
                    $0.camera.writeAccess = connected?.writeAccess.reportLabel
                }
            }
            slotReader.detectFilmSimulationDrift()
            // The connect/probe sequence is what the trace is for; the session being used is not
            // characterized — except a push, which `pushExclusively` arms the trace around.
            reports.isTracing = false
            reports.persist()
            // Only start the keepalive if the session is genuinely up (the slot read may have failed).
            if keepAlive, case .connected = status { startKeepAlive(epoch: e) }
        } catch {
            // Don't leak a transport (and the session it may have half-opened) on a failed open.
            await transport.close()
            guard session.epoch.isCurrent(e, "connect failure") else { return }
            let reason = (error as? CameraError)?.errorDescription ?? AppLog.bounded(error)
            CameraLog.error("Connect: open failed — \(reason)")
            let grants = transport is ImageCaptureTransport ? discovery.authorizationSummary : nil
            reports.recordConnectionFailure(stage: "open", reason: reason,
                                    productName: productName ?? transport.productName,
                                    usb: transport.usbIdentity,
                                    identification: identification.reportLabel,
                                    authorization: grants)
            status = .failed((error as? CameraError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// A body no entry matches is identified by what it answered: `GetDeviceInfo` carrying a product
    /// name, serial and firmware names it (the rule the README states under Supported cameras), and
    /// the registry's provisional model gives the codec its field knowledge. Without that answer it
    /// stays unknown.
    private static func resolve(_ identification: ModelIdentification, productName: String,
                                deviceInfo: FujiPTP.DeviceInfo?) -> ModelIdentification {
        guard case .unknown = identification, let deviceInfo, deviceInfo.namesTheBody else { return identification }
        return .unlisted(provisional: CameraModelRegistry.shared.provisionalModel(productName: productName))
    }

    func disconnect() async {
        session.advanceEpoch()   // retire anything still in flight from the outgoing session
        CameraLog.info("Disconnect requested")
        cancelRecovery()
        keepAlive?.cancel(); keepAlive = nil
        isSuspended = false
        connectedDevice = nil
        await transport?.attachTrace(nil)
        await transport?.close()
        reports.persist()   // the report survives the session; the raw slot bytes in it are the rollback source
        transport = nil; connected = nil; slotReader.reset(); slotWriter.reset()
        conversion.reset()
        status = .disconnected
    }

    // MARK: - Session health (keepalive, background suspend, disconnect recovery)

    /// Poll a cheap property while the camera is idle. This keeps the PTP session from timing out
    /// during inactivity and, when the session has already died, surfaces it as a reconnectable
    /// failure instead of leaving the app appearing connected until it's restarted.
    private func startKeepAlive(epoch e: UInt64) {
        keepAlive?.cancel()
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { return }
                await self?.pingIfIdle(epoch: e)
            }
        }
    }

    private func pingIfIdle(epoch e: UInt64) async {
        guard session.epoch.isCurrent(e, "keepalive tick") else { return }
        // While the app is backgrounded, ImageCaptureCore suspends device I/O without closing the
        // session (see `suspendForBackground`) — a ping sent into that suspension would fail for a
        // reason that has nothing to do with the session being dead.
        guard !isSuspended else { return }
        // Skip while an operation is in flight — that traffic already keeps the session warm, and the
        // transport serializes transactions so a stray read isn't harmful, just unnecessary.
        guard case .connected = status, let transport else { return }
        do {
            _ = try await transport.readProperty(FujiPTP.Prop.slotSelector)
        } catch {
            guard session.epoch.isCurrent(e, "keepalive failure") else { return }
            guard !sessionSurvives(error, probe: "Keepalive ping") else { return }
            CameraLog.error("Keepalive ping failed: \(error.cameraLogDescription)")
            handleConnectionLost(epoch: e, reason: "keepalive ping failed")
        }
    }

    /// Whether a failed health probe leaves the session intact.
    ///
    /// The probe reads `FujiPTP.Prop.slotSelector`, which is the cheapest property the app knows — but "cheapest the
    /// app knows" is not "present on every body in every USB mode". A camera that refuses it has
    /// still answered, and an answer is the only thing the probe was ever asking for. Logged once
    /// per session (`probeRefusalLogged`), because the alternative is a line every five seconds.
    private func sessionSurvives(_ error: Error, probe: String) -> Bool {
        guard let camera = error as? CameraError, camera.provesCameraAnswered else { return false }
        if !probeRefusalLogged {
            probeRefusalLogged = true
            CameraLog.info("\(probe): camera answered \(error.cameraLogDescription) — the camera is still responding, so the connection is being kept.")
            reports.note("health probe: 0xD18C answered \(error.cameraLogDescription) — session kept (a PTP response proves the camera is still talking)")
        }
        return true
    }

    /// The shared browser suspends device I/O around app backgrounding without closing the PTP
    /// session (`CameraDeviceBrowser.onSuspend`) — pause the keepalive rather than let it read that
    /// as loss, which would turn "the user checked their messages" into a dropped connection.
    private func suspendForBackground() {
        guard !isSuspended, transport != nil else { return }
        isSuspended = true
        keepAlive?.cancel(); keepAlive = nil
        cancelRecovery()
        CameraLog.info("App backgrounded — pausing keepalive; session stays open")
    }

    private func resumeFromBackground() async {
        guard isSuspended else { return }
        isSuspended = false
        // `suspendForBackground` cancels an in-flight recovery, which would leave the session
        // showing "Reconnecting…" with nothing running — a spinner that never resolves. Restart it
        // rather than strand it; the expected window makes this reachable far more often.
        // Stranded means: the transport is gone, nothing is recovering it, and the session still
        // thinks it is connected — which is exactly the state a cancelled recovery leaves behind
        // and no other path does (give-up and disconnect both clear `connected`).
        if transport == nil, connected != nil, recovery == nil, case .working = status {
            CameraLog.info("App foregrounded with a recovery that backgrounding cancelled — starting it again")
            beginRecovery(reason: "recovery interrupted by backgrounding")
            return
        }
        guard let transport, case .connected = status else { return }
        let e = session.epoch.current
        CameraLog.info("App foregrounded — probing before resuming keepalive")
        do {
            _ = try await transport.readProperty(FujiPTP.Prop.slotSelector)
            guard session.epoch.isCurrent(e, "resume probe") else { return }
            startKeepAlive(epoch: e)
        } catch {
            guard session.epoch.isCurrent(e, "resume probe failure") else { return }
            if sessionSurvives(error, probe: "Resume probe") {
                startKeepAlive(epoch: e)
                return
            }
            CameraLog.error("Resume probe failed: \(error.cameraLogDescription)")
            handleConnectionLost(epoch: e, reason: "resume probe failed")
        }
    }

    /// React to an unexpected disconnect (USB removal or a dead session): close the dead transport
    /// and attempt silent recovery — see `beginRecovery`.
    private func handleConnectionLost(epoch e: UInt64, reason: String) {
        guard session.epoch.isCurrent(e, "connection-lost (\(reason))") else { return }
        guard transport != nil else { return }   // ignore duplicate signals (removal + failed ping)
        guard !isSuspended else {
            CameraLog.info("Connection-lost signal ignored while suspended (\(reason))")
            return
        }
        if removalIsExpected {
            CameraLog.info("Connection lost: \(reason) — expected at this step, so the session is being waited for rather than mourned")
        } else {
            CameraLog.error("Connection lost: \(reason)")
        }
        // Read before recovery's "Reconnecting…" covers the status, and only for a fresh loss: a
        // drop during one of recovery's own reconnects says nothing about what the user was doing.
        if recovery == nil {
            lossInterruptedOperation = Self.lossInterruptsOperation(status: status, exclusiveOperation: gate.runningOperation)
        }
        keepAlive?.cancel(); keepAlive = nil
        let dead = transport
        transport = nil
        Task { await dead?.close() }   // best-effort on an already-gone device
        beginRecovery(reason: reason)
    }

    /// Try to silently re-establish a session that just dropped. Up to 3 attempts with backoff; ends the session — see `endUnrecoveredLoss` —
    /// if the camera doesn't reappear, or if a *different* camera appears instead (never
    /// auto-adopted — this app writes recipes, and pushing to a body the user didn't plug in is the
    /// one mistake unplugging can't undo). Recoveries happening too often to be a fluke go straight
    /// to the cable card instead.
    private func beginRecovery(reason: String) {
        guard recovery == nil else { return }
        guard let previousDevice = connectedDevice else {
            Task { await endUnrecoveredLoss() }
            return
        }
        // An instructed unplug is not evidence of a bad cable, and the write pass asks for three
        // of them inside two minutes — exactly the shape this throttle exists to catch.
        let expected = removalIsExpected
        recentRecoveries.removeAll { $0.timeIntervalSinceNow < -120 }
        guard expected || recentRecoveries.count < 3 else {
            CameraLog.error("Recovery: giving up — the connection has dropped repeatedly in the last 2 minutes")
            connected = nil; slotReader.clearSlots()
            status = .failed(CameraError.chargeOnlyCableOrAdapter.message)
            return
        }

        status = .working(expected ? "Waiting for the camera to come back…" : "Reconnecting…")
        let (delays, deviceWait) = RecoveryPolicy.plan(expected: expected)
        recovery = Task { [weak self] in
            // Before this task ends, `recovery` is dropped only through `cancelRecovery`, which
            // cancels it first. So a cancelled task no longer owns the handle, which may already
            // belong to its replacement, and only a task that ends uncancelled clears it.
            defer { if !Task.isCancelled { self?.recovery = nil } }
            for (attempt, delay) in delays.enumerated() {
                try? await Task.sleep(nanoseconds: delay)
                guard let self, !Task.isCancelled, !self.isSuspended else { return }
                CameraLog.info("Recovery attempt \(attempt + 1)/\(delays.count) — \(reason)")
                guard let device = try? await self.discovery.firstCamera(timeout: deviceWait) else { continue }
                // A cancel during the wait ends it, and the next pass returns; one that lands as the
                // camera is found does not, so it is honoured here. Without this, a manual
                // Reconnect that cancelled the task would still be followed by this task's own
                // `connect`, tearing down the session the tap had just made.
                guard !Task.isCancelled, !self.isSuspended else { return }
                guard device.usbVendorID == previousDevice.usbVendorID,
                      device.usbProductID == previousDevice.usbProductID,
                      device.name == previousDevice.name else {
                    CameraLog.error("Recovery: a different camera appeared — refusing to auto-adopt it")
                    break
                }
                self.connectedDevice = device
                let hwTransport = device.makeTransport()
                let identification = CameraModelRegistry.shared.identify(productName: hwTransport.productName)
                await self.connect(using: hwTransport, identification: identification, productName: hwTransport.productName,
                                   firmwareVersion: hwTransport.firmwareVersion, keepAlive: true)
                if case .connected = self.status {
                    if !expected { self.recentRecoveries.append(Date()) }
                    CameraLog.info("Recovery: recovered on attempt \(attempt + 1)")
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            CameraLog.error("Recovery: gave up after \(delays.count) attempts")
            await self.endUnrecoveredLoss()
        }
    }

    /// Stops the recovery under way and drops its handle, the one way the handle is dropped before
    /// its task ends. The two go together: dropping the handle without cancelling would let the old
    /// task, on ending, clear a replacement's handle; cancelling without dropping it would leave
    /// `isRecovering` set and `beginRecovery` refusing every later loss.
    private func cancelRecovery() {
        recovery?.cancel()
        recovery = nil
    }

    /// Recovery is over and the camera isn't back.
    ///
    /// Cut off mid-operation, the warning card stays: a read or a write stopped part-way, and the
    /// slot it was touching is worth checking. With nothing running there is nothing to check — the
    /// usual cause is a camera unplugged without tapping Disconnect — so the session ends the way
    /// Disconnect ends it, with no warning.
    private func endUnrecoveredLoss() async {
        guard !lossInterruptedOperation else {
            connected = nil; slotReader.clearSlots()
            status = .failed(CameraError.disconnectedDuringOperation.message)
            return
        }
        CameraLog.info("Recovery: nothing was running when the camera went, so the session ends as a plain disconnect")
        await disconnect()
    }
}
