import SwiftUI

/// The camera workspace: connect, see detected model/firmware and slot contents, and launch the
/// import / push flows. Connection state reads as one confident status card; slots show what's
/// loaded; Import / Push are equal-weight buttons.
struct CameraView: View {
    @Environment(CameraServices.self) private var camera

    /// Gates the Demo Camera and the property report — see `DiagnosticMode`.
    @AppStorage(DiagnosticMode.key) private var diagnosticMode = false

    @State private var showingGuide = false
    @State private var showingImport = false
    @State private var showingPush = false
    @State private var showingPropertyReport = false
    @State private var showingConnectionLog = false
    @State private var showingBackupShare = false
    @State private var showingBackupPicker = false
    @State private var restoreTarget: RestoreRequest?
    @State private var backupError: String?
    @State private var pendingBackup: CameraBackup?
    /// What to open the Camera Test with, or nil when it isn't showing.
    ///
    /// Carried as one value rather than two `@State` flags beside an `isPresented` sheet: one value
    /// avoids a stale-parameter race, where the sheet builds with the previous wave.
    @State private var cameraTest: CameraTestRequest?
    @State private var recoveryTest: GuidedRecoveryRecord?
    /// What the Camera Test row shows, read from the store when the tab appears and whenever a test
    /// sheet closes. Held in state because nothing on this screen observes those files: the flow
    /// writes them from inside a sheet, and a body that read them directly would only notice when
    /// something else redrew it — and would decode the history on every camera status change.
    @State private var testRecords = CameraTestRecords()

    private struct CameraTestRecords {
        /// The live session the tester has actually started. Opening the test saves a session at
        /// its intro, and reading the intro is not starting: until Begin, the row stays the
        /// invitation rather than claiming a test is in progress.
        var live: GuidedTestSession?
        var latest: GuidedTestSession?
        var recoveries: [GuidedRecoveryRecord] = []

        static func load() -> CameraTestRecords {
            let live = GuidedTestStore.load().flatMap { session in
                session.isLive && (session.step != .intro || !session.completedSteps.isEmpty) ? session : nil
            }
            return CameraTestRecords(live: live, latest: GuidedTestStore.loadHistory().last,
                                     recoveries: GuidedRecoveryStore.unresolvedRecords())
        }
    }

    private struct CameraTestRequest: Identifiable {
        let id = UUID()
        /// Where to open, when something specific sent the tester there — a failed connect goes
        /// straight to the questions about what happened.
        var entry: GuidedTestStep?
        var wave = 1
        var sessionID: String?
    }

    /// A recognized body the app selects no slot on (`ConnectedCamera.slotsUnreachable`). Not "we
    /// won't write to it": there is nothing there to read either, so the screen explains the camera
    /// instead of offering it slots and then failing to fill them.
    private var hasNoSlots: Bool { camera.session.connected?.slotsUnreachable ?? false }

    private var cardState: CameraCardState? {
        CameraCardState(isConnected: camera.session.isConnected, isRecovering: camera.connector.isRecovering)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // While reconnecting the card says so. Recovery's own attempts would otherwise
                    // flash "Connecting…", a failure with Connection Help, and slot reads above it.
                    if cardState != .reconnecting { transientStatus }
                    if camera.session.isConnected {
                        connectedCard
                        if let banner = camera.session.connected.flatMap({ $0.identification.guessBanner(productName: $0.productName) }) {
                            Label { Text(banner) } icon: {
                                Image(systemName: "questionmark.diamond.fill").foregroundStyle(Theme.warning)
                            }
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .themedCard(cornerRadius: 16)
                        }
                        if camera.session.connected?.isUnsupported == true {
                            unrecognizedCard
                            cameraTestSection
                        } else if hasNoSlots {
                            // `slotsCard` is hidden rather than emptied: "No slots read yet."
                            // is untrue here and implies a pull-to-refresh would help.
                            noSlotProtocolCard
                            cameraTestSection
                        } else {
                            // What was read before the drop, until the reconnect reads it again.
                            slotsCard.opacity(cardState == .reconnecting ? 0.45 : 1)
                        }
                        driftCard
                        divergenceCard
                        // Neither tile can ever enable on a body with no slots — Import needs an
                        // occupied one and Push needs write support — and two permanently greyed
                        // tiles read as something broken rather than something explained.
                        if !hasNoSlots { actionButtons }
                        if camera.session.model != nil, !camera.slotWriter.canPush, !hasNoSlots {
                            Text(camera.slotWriter.pushBlockReason ?? "Push is disabled for this camera because its parameter encodings haven't been verified on hardware yet. Reading recipes is always safe.")
                                .font(.caption)
                                .foregroundStyle(Theme.ink3)
                                .padding(.horizontal, 4)
                        }
                        backupRow
                        if camera.session.model != nil { reportProblemRow }
                    } else {
                        connectCard
                    }
                    helpButton
                    if !testLeadsThePage { cameraTestSection }
                    // Reachable whether or not the camera is connected — unlike the property report,
                    // this is exactly what's needed right after a failed or flaky connect attempt.
                    if diagnosticMode { connectionLogButton }
                    if camera.session.isConnected, diagnosticMode { propertyReportButton }
                }
                .padding(18)
            }
            .background(Theme.paper.ignoresSafeArea())
            .navigationTitle("Camera")
            .settingsToolbarItem()
            .toolbar {
                if camera.session.isConnected {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Disconnect") { Task { await camera.connector.disconnect() } }
                    }
                }
            }
            .sheet(isPresented: $showingGuide) {
                ConnectionGuideView()
            }
            .sheet(item: $cameraTest, onDismiss: refreshTestRecords) { request in
                GuidedTestView(entry: request.entry, wave: request.wave, sessionID: request.sessionID)
            }
            .sheet(item: $recoveryTest, onDismiss: refreshTestRecords) { record in
                GuidedRecoveryView(record: record)
            }
            .onAppear(perform: refreshTestRecords)
            .sheet(isPresented: $showingImport) { NavigationStack { CameraImportView() } }
            .sheet(isPresented: $showingPush) { NavigationStack { PushView(preselectedRecipe: nil) } }
            .sheet(item: $restoreTarget) { target in
                RestoreView(slot: target.slot, slotName: target.name,
                            saved: target.saved, source: target.source)
            }
            .sheet(isPresented: $showingBackupPicker) {
                ContentPicker(contentTypes: [.json], allowsMultiple: false) { urls in
                    showingBackupPicker = false
                    guard let url = urls.first else { return }
                    loadBackup(from: url)
                }
            }
            .sheet(item: $pendingBackup) { backup in
                NavigationStack { backupSlotPicker(backup) }
            }
            .alert("Couldn't Read That Backup",
                   isPresented: Binding(isPresent: $backupError)) {
                Button("OK", role: .cancel) { backupError = nil }
            } message: { Text(backupError ?? "") }
            .sheet(isPresented: $showingPropertyReport) { NavigationStack { CameraPropertyReportView() } }
            .sheet(isPresented: $showingConnectionLog) { NavigationStack { ConnectionLogView() } }
            // `requestRefresh()`, not `refresh()`: `connect` reports `.connected` before it
            // awaits its own slot read, so this is pullable while that read is still walking slots.
            // A refused refresh leaves the screen as it was; the gate logs the refusal.
            .refreshable { if camera.session.isConnected { _ = try? await camera.slotReader.requestRefresh() } }
        }
    }

    // MARK: Transient status (connecting / working / failed)

    @ViewBuilder
    private var transientStatus: some View {
        switch camera.session.status {
        // Ahead of the status, which a cancel has already set to disconnected: the connect can
        // still be inside a session open, and the Connect rows wait for it.
        case _ where camera.connector.connectProgress == .cancelling:
            statusCard {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Cancelling…").foregroundStyle(Theme.ink2)
                }
            }
        case .connecting:
            statusCard {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Connecting…").foregroundStyle(Theme.ink2)
                    // Only a connect the user started; recovery's reconnects also pass through
                    // `.connecting`, and Disconnect ends those.
                    if camera.connector.connectProgress == .running {
                        Spacer()
                        Button("Cancel") { Task { await camera.connector.cancelConnect() } }
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
        case .working(let message):
            statusCard {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(message).foregroundStyle(Theme.ink2)
                }
            }
        case .failed(let message):
            statusCard {
                VStack(alignment: .leading, spacing: 10) {
                    Label { Text(message) } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                    }
                    HStack(spacing: 16) {
                        Button("Connection Help") { showingGuide = true }
                            .font(.subheadline.weight(.semibold))
                        // A camera that never appears is the most common failure and the one
                        // the app can say least about by itself — it has the two permission states
                        // and the stage that failed, and nothing that separates a charge-only cable
                        // from the wrong USB mode. That part has to be asked.
                        Button("Tell Us What Happened") {
                            cameraTest = CameraTestRequest(entry: .noCamera)
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                }
            }
        case .connected, .disconnected:
            EmptyView()
        }
    }

    private func statusCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .themedCard(cornerRadius: 16)
    }

    // MARK: Connected

    /// One confident status card: live dot, transport, serif model name, key facts. While a dropped
    /// session is recovering, the card turns grey and the dot becomes a spinner, so the camera last
    /// seen never reads as connected.
    @ViewBuilder
    private var connectedCard: some View {
        if let connected = camera.session.connected, let state = cardState {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    switch state {
                    case .live:
                        Circle()
                            .fill(Color(red: 0.56, green: 0.89, blue: 0.69))
                            .frame(width: 10, height: 10)
                            .background(Circle().fill(Color(red: 0.56, green: 0.89, blue: 0.69).opacity(0.25)).frame(width: 18, height: 18))
                    case .reconnecting:
                        // Laid out at the dot's size and allowed to overflow it, as the dot's halo
                        // does, so the header text doesn't move when the state changes.
                        ProgressView()
                            .controlSize(.mini)
                            .tint(Theme.onAccent)
                            .frame(width: 10, height: 10)
                    }
                    Text(linkLabel(for: connected, in: state))
                        .font(.caption.weight(.semibold))
                        .kerning(1.0)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.onAccent.opacity(0.85))
                }
                Text(connected.model?.displayName ?? connected.productName)
                    .font(Theme.serif(24))
                    .foregroundStyle(Theme.onAccent)
                HStack(spacing: 16) {
                    if let fw = connected.firmwareVersion {
                        Text("Firmware \(fw)")
                    }
                    // No slot range for a body with no slots, or when the count is unknown because the
                    // slot walk failed: "Slots C1–C0" would be worse than none, and so would a guess.
                    if connected.model != nil, !hasNoSlots, camera.slotReader.effectiveSlotCount > 0 {
                        Text("Slots C1–C\(camera.slotReader.effectiveSlotCount)")
                    }
                    // One source for the seal, shared with the test's identity step — which asks the
                    // tester to confirm it, and records what they were shown.
                    Label(connected.capabilityBadge.text, systemImage: connected.capabilityBadge.symbol)
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.onAccent.opacity(0.9))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            // Grayscale keeps the green's luminance, so `onAccent` text keeps its contrast in both
            // appearances.
            .grayscale(state == .reconnecting ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: state)
            .accessibilityElement(children: .combine)
        }
    }

    /// The card's header: whether the session is live, and over what.
    private func linkLabel(for connected: ConnectedCamera, in state: CameraCardState) -> String {
        let transport = connected.isDemo ? "Demo" : "USB"
        switch state {
        case .live: return "Connected · \(transport)"
        case .reconnecting: return "Reconnecting · \(transport)"
        }
    }

    /// The unrecognized-body path's whole purpose: turn "not supported" into an artifact that gets
    /// the body supported. The report is on disk already; this card says what it holds and leaves
    /// sending it to the Camera Test, whose results screen shows the report, as readable text and as
    /// the attached JSON, before anything is shared (`DiagnosticsReportView`).
    @ViewBuilder
    private var unrecognizedCard: some View {
        if let report = camera.reports.report {
            VStack(alignment: .leading, spacing: 10) {
                Label("This camera isn't supported yet", systemImage: "questionmark.diamond")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text("Fuji Cookbook read everything \(report.camera.productName) would show it and changed nothing. Sharing a report is what gets this camera supported. It contains what the camera says about itself and the recipe settings it currently holds — nothing leaves the phone until you share it.")
                    .font(.caption)
                    .foregroundStyle(Theme.ink2)
                // No share button here: the Camera Test below leads to the fuller report — the same
                // camera data plus the logs and the answers only a person can give — and two
                // buttons offering different halves of one thing would make the weaker one look
                // like the quicker route.
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themedCard(cornerRadius: 16)
        }
    }

    /// A recognized body whose firmware has no custom-slot protocol.
    ///
    /// The registry already records that these bodies have no working slot select
    /// (`CameraModelRegistry`, which cites the record), so sending one would only show the tester
    /// "Couldn't select custom slot C1 on the camera": an error, for a fact known before the cable
    /// went in. The connection is fine; the camera doesn't have the feature. So this says that
    /// plainly, in the body's own words (`writeSupport.blockReason`), and points at the Camera Test,
    /// whose report is what confirms or overturns the bodies the registry holds on inference
    /// (`GuidedTestView`).
    @ViewBuilder
    private var noSlotProtocolCard: some View {
        if camera.reports.report != nil, let model = camera.session.model {
            VStack(alignment: .leading, spacing: 10) {
                // No model name here: the green card directly above already names the body, and
                // `blockReason` opens with it too — three in a row read as a stutter.
                Label("No custom slots over USB", systemImage: "lock.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text("\(model.writeSupport.blockReason ?? "This camera's firmware doesn't expose custom slots over USB.") Fuji Cookbook read everything it would show and changed nothing — it didn't even ask the camera to select a slot.")
                    .font(.caption)
                    .foregroundStyle(Theme.ink2)
                Text("Sharing a report is what gets this camera's support confirmed. It holds what the camera says about itself and which settings it answered for — nothing leaves the phone until you share it. The Camera Test walks you through producing one.")
                    .font(.caption)
                    .foregroundStyle(Theme.ink2)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themedCard(cornerRadius: 16)
        }
    }

    /// A slot that changed since the app last wrote it. Distinct from `divergenceCard`, which is
    /// about values the app can't read: this is a value it wrote, verified, and later found
    /// replaced. The app didn't do it, and says so — on a dial body, the dial is the usual answer.
    @ViewBuilder
    private var driftCard: some View {
        if !camera.slotReader.filmSimulationDrift.isEmpty {
            let dial = camera.session.model?.hasFilmSimulationDial ?? false
            VStack(alignment: .leading, spacing: 10) {
                Label(camera.slotReader.filmSimulationDrift.count == 1 ? "A slot changed since you last wrote it"
                                                              : "\(camera.slotReader.filmSimulationDrift.count) slots changed since you last wrote them",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                ForEach(camera.slotReader.filmSimulationDrift) { drift in
                    Text(drift.summary + ".")
                        .font(.caption)
                        .foregroundStyle(Theme.ink2)
                }
                Text(dial
                     ? "Fuji Cookbook didn't do this. On the \(camera.session.model?.displayName ?? "camera"), the Film Simulation dial can change a custom slot's film simulation — check that it's on “C”. Push the recipe again to restore it."
                     : "Fuji Cookbook didn't do this. Push the recipe again to restore it, and if it keeps happening, send a report.")
                    .font(.caption)
                    .foregroundStyle(Theme.ink2)
                NavigationLink {
                    DiagnosticsReportView()
                } label: {
                    Label("Report a Problem", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themedCard(cornerRadius: 16)
        }
    }

    /// Slots whose contents the codec could not fully read.
    private var divergentSlots: [CameraSlot] { camera.slotReader.slots.filter { !$0.unsupportedFields.isEmpty } }

    /// Tells the user when a slot holds values the codec doesn't recognize, and offers a report.
    ///
    /// A body whose encodings differ from ours produces recipes that look plausible, so without
    /// this card the misread goes unnoticed and unreported. It renders for recognized and guessed
    /// bodies alike: a *recognized* body reading wrongly is the case nothing else on this screen
    /// covers.
    @ViewBuilder
    private var divergenceCard: some View {
        if !divergentSlots.isEmpty {
            let count = divergentSlots.reduce(0) { $0 + $1.unsupportedFields.count }
            let names = divergentSlots.map(\.label).joined(separator: ", ")
            VStack(alignment: .leading, spacing: 10) {
                Label("Some settings didn't read cleanly", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text("Fuji Cookbook read \(count) value\(count == 1 ? "" : "s") on \(names) that it doesn't recognize on this camera. It left \(count == 1 ? "that setting" : "those settings") blank rather than guessing, so what you see may be incomplete — and that's exactly the kind of fact that gets this camera properly supported.")
                    .font(.caption)
                    .foregroundStyle(Theme.ink2)
                NavigationLink {
                    DiagnosticsReportView()
                } label: {
                    Label("Report a Problem", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accent))
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themedCard(cornerRadius: 16)
        }
    }

    /// One pending restore: which slot, from where, and the bytes.
    struct RestoreRequest: Identifiable {
        let slot: Int
        let name: String
        let saved: [UInt16: Data]
        let source: RestoreView.Source
        var id: Int { slot }
    }

    /// Save every slot, and put one back.
    ///
    /// The save half is free — `SlotReader.refresh()` already read these bytes — and it is the only thing
    /// here that carries no risk at all, which is why it leads. The restore half is a push in every
    /// respect but its values, so it is offered **one slot at a time**: that keeps the exposure
    /// identical to the push it undoes, and it matches how damage actually happens.
    ///
    /// A quiet row below Import and Push rather than a card above them: Undo Last Push already
    /// covers a slot's latest push, so this is the fullest way back, not the only one.
    @ViewBuilder
    private var backupRow: some View {
        if camera.session.model != nil, camera.slotReader.slots.contains(where: { $0.isOccupied }) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Save every slot's exact settings to a file you keep, so you can put any slot back later.")
                    .font(.caption)
                    .foregroundStyle(Theme.ink3)
                // Side by side, stacked when the largest text sizes leave no room for both.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { backupButtons }
                    VStack(alignment: .leading, spacing: 8) { backupButtons }
                }
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sheet(isPresented: $showingBackupShare) {
                if let backup = camera.slotReader.slotBackup {
                    ShareBundle.backupShareSheet(backup)
                }
            }
        }
    }

    @ViewBuilder
    private var backupButtons: some View {
        Button { showingBackupShare = true } label: {
            Label("Save Backup", systemImage: "square.and.arrow.up")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
        .disabled(camera.slotReader.slotBackup == nil)
        if camera.slotWriter.canPush {
            Button { showingBackupPicker = true } label: {
                Label("Restore a Slot…", systemImage: "arrow.uturn.backward")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
    }

    /// Which slot to put back. One at a time, deliberately — see `backupRow`.
    @ViewBuilder
    private func backupSlotPicker(_ backup: CameraBackup) -> some View {
        List {
            Section {
                ForEach(backup.slots.sorted { $0.index < $1.index }, id: \.index) { slot in
                    Button {
                        guard let saved = backup.properties(forSlot: slot.index) else { return }
                        pendingBackup = nil
                        restoreTarget = RestoreRequest(slot: slot.index,
                                                       name: slot.name ?? "C\(slot.index)",
                                                       saved: saved,
                                                       source: .backup(name: backup.suggestedFilename))
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("C\(slot.index)").font(.subheadline.weight(.semibold))
                                Text(slot.occupied ? (slot.name ?? slot.summary ?? "Occupied")
                                                   : "Empty when this backup was taken")
                                    .font(.caption).foregroundStyle(Theme.ink3)
                            }
                            Spacer()
                            if slot.occupied { Image(systemName: "chevron.right").font(.caption) }
                        }
                    }
                    .disabled(!slot.occupied || backup.properties(forSlot: slot.index) == nil)
                }
            } footer: {
                Text("A slot that was empty can't be put back. " + CameraBackup.slotCannotBeEmptied)
            }
        }
        .navigationTitle("Restore Which Slot?")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { pendingBackup = nil } }
        }
    }

    /// Read a picked backup, refuse it if it belongs to another body, then ask which slot.
    ///
    /// The body check is not pedantry: a backup is raw property bytes, and writing one camera's
    /// bytes into another is the one mistake this feature makes newly possible.
    private func loadBackup(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let backup = try CameraBackup.decode(try Data(contentsOf: url))
            if let connected = camera.session.connected,
               !backup.camera.isFromBody(productName: connected.productName,
                                         registryModelID: connected.registryModel?.id) {
                backupError = CameraBackupError.differentBody(
                    backup: backup.camera.modelID ?? backup.camera.productName,
                    connected: connected.registryModel?.id ?? connected.productName).errorDescription
                return
            }
            pendingBackup = backup
        } catch {
            backupError = error.localizedDescription
        }
    }

    /// The route for people who want to help: one quiet row at the end of the page.
    ///
    /// Offered for every connected body, verified or not: every other report route here is worded
    /// for a failure, and a clean session on an unverified body is the one that promotes it. The
    /// README and CONTRIBUTING send contributors to it by its title. For a body with no match or no
    /// slots it follows the card that explains that (`testLeadsThePage`).
    ///
    /// Disconnected, it starts nothing new but keeps what's already begun: a live test (menu
    /// comparisons require unplugging), saved results and unresolved recovery records.
    ///
    /// The camera report alone can't stand in for the test: whether the app's reading matches the
    /// camera's own menu, and whether a pushed recipe survives a power cycle, take a person to answer.
    @ViewBuilder
    private var cameraTestSection: some View {
        let session = testRecords.live
        let latest = testRecords.latest
        let recoveries = testRecords.recoveries
        if session != nil || camera.session.isConnected || latest != nil || !recoveries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if let session {
                    cameraTestRow(title: "Camera Test in progress",
                                  subtitle: "\(GuidedTestFlow.positionLabel(of: session.step, in: session)). Pick up where you left off.",
                                  systemImage: "arrow.right.circle") {
                        cameraTest = CameraTestRequest(wave: session.wave)
                    }
                } else if camera.session.isConnected {
                    cameraTestRow(title: "Help improve camera support",
                                  subtitle: "A guided Camera Test shows how your \(testedCameraName) works with Fuji Cookbook.",
                                  systemImage: "checklist") {
                        cameraTest = CameraTestRequest()
                    }
                } else if let latest {
                    cameraTestRow(title: "Your Camera Test results",
                                  subtitle: "Review or share your last test.",
                                  systemImage: "checklist") {
                        cameraTest = CameraTestRequest(wave: latest.wave, sessionID: latest.id)
                    }
                }
                if let latest, session != nil || camera.session.isConnected {
                    Button("Review Saved Test Results") {
                        cameraTest = CameraTestRequest(wave: latest.wave, sessionID: latest.id)
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 4)
                }
                ForEach(recoveries) { record in
                    Button {
                        recoveryTest = record
                    } label: {
                        Label("Review \(record.backup.camera.productName) settings", systemImage: "arrow.uturn.backward.circle")
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 4)
                }
            }
        }
    }

    /// A body with no match or no slots has nothing else to do here, so the test follows the card
    /// that explains it instead of waiting at the end of the page.
    private var testLeadsThePage: Bool {
        camera.session.isConnected && (camera.session.model == nil || hasNoSlots)
    }

    /// "your X-S20", in the invitation. The demo's display name is written for a model list.
    private var testedCameraName: String {
        guard let connected = camera.session.connected else { return "camera" }
        if connected.isDemo { return "demo camera" }
        return connected.model?.displayName ?? connected.productName
    }

    /// The quiet row: a card that reads as a place to go, not a task to do.
    private func cameraTestRow(title: String, subtitle: String, systemImage: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.ink3)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .themedCard(cornerRadius: 16)
    }

    private func refreshTestRecords() {
        testRecords = .load()
    }

    /// The always-there route for a *recognized* body.
    ///
    /// `unrecognizedCard` only appears when nothing matched, and `divergenceCard` only when the
    /// decode noticed something. The case neither covers is the dangerous one: a body the app is
    /// confident about, reading and pushing without complaint, getting it wrong. Not gated on
    /// Diagnostic Mode — a tester will not find that toggle.
    private var reportProblemRow: some View {
        ReportProblemRow(prompt: "Recipes look wrong, or a push didn't take?", chevron: true)
            .padding(.horizontal, 4)
            .buttonStyle(.plain)
    }

    @ViewBuilder
    private var slotsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Theme.SectionLabel("Custom Slots")
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                if camera.slotReader.slots.isEmpty {
                    Text("No slots read yet.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                } else {
                    ForEach(camera.slotReader.slots) { slot in
                        if slot.index != camera.slotReader.slots.first?.index {
                            Rectangle().fill(Theme.line).frame(height: 1)
                        }
                        SlotRow(slot: slot)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            // The free undo: no file, no export, just the bytes this slot held
                            // before the app last wrote to it. Offered here rather than as a card
                            // because it is about *this* slot and only exists for slots we pushed to.
                            .contextMenu {
                                if camera.slotWriter.canPush, let saved = camera.reports.history.lastPushPriorBytes(forSlot: slot.index) {
                                    Button {
                                        restoreTarget = RestoreRequest(
                                            slot: slot.index,
                                            // The name the push *replaced*, never the slot's current
                                            // one; `undoName` holds the rule.
                                            name: camera.reports.history.undoName(forSlot: slot.index),
                                            saved: saved, source: .lastPush)
                                    } label: {
                                        Label("Undo Last Push to C\(slot.index)", systemImage: "arrow.uturn.backward")
                                    }
                                }
                            }
                    }
                }
            }
            .themedCard(cornerRadius: 16)
        }
    }

    private var actionsAvailable: Bool {
        Self.actionsAvailable(status: camera.session.status, cardState: cardState)
    }

    /// Whether Import and Push may open: a live session with nothing running.
    ///
    /// `connected` stays set while a dropped session recovers, so the card can show the camera as
    /// reconnecting, but the transport is down for the whole recovery. That includes a failed
    /// attempt's `.failed` while the next one waits, which `isBusy` alone doesn't cover.
    nonisolated static func actionsAvailable(status: CameraSession.Status, cardState: CameraCardState?) -> Bool {
        cardState == .live && !status.isBusy
    }

    /// Import / Push as equal-weight tiles instead of list rows.
    private var actionButtons: some View {
        HStack(spacing: 10) {
            actionTile(title: "Import",
                       systemImage: "square.and.arrow.down",
                       prominent: false,
                       enabled: actionsAvailable && camera.slotReader.slots.contains { $0.isOccupied }) {
                showingImport = true
            }
            actionTile(title: "Push",
                       systemImage: "square.and.arrow.up",
                       prominent: true,
                       enabled: actionsAvailable && camera.slotWriter.canPush) {
                showingPush = true
            }
        }
    }

    /// The outline tile and the filled tile share padding 14, so the pair stays one height.
    @ViewBuilder
    private func actionTile(title: String, systemImage: String, prominent: Bool,
                            enabled: Bool, action: @escaping () -> Void) -> some View {
        let label = VStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.title3.weight(.medium))
            Text(title)
                .font(.footnote.weight(.semibold))
        }
        if prominent {
            Button(action: action) {
                label
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accent))
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
        } else {
            Button(action: action) { label }
                .buttonStyle(.outline)
                .disabled(!enabled)
        }
    }

    // MARK: Disconnected

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Theme.SectionLabel("Connect")
                .padding(.horizontal, 4)
            // One connect at a time: the rows wait out the one under way, whose progress shows above.
            VStack(spacing: 0) {
                connectRow(title: "Connect Camera (USB)", systemImage: "cable.connector") {
                    Task { await camera.connector.connectHardware() }
                }
                if diagnosticMode {
                    Rectangle().fill(Theme.line).frame(height: 1)
                    connectRow(title: "Connect Demo Camera", systemImage: "play.circle") {
                        Task { await camera.connector.connectDemo() }
                    }
                    // The demo model converts, so the develop step's profile harvest never shows
                    // on it. This one presents as a GFX100 — read, write, no Kitchen — which is the
                    // only way to walk that step without owning such a body.
                    connectRow(title: "Connect Demo as GFX100 (no Kitchen)", systemImage: "play.circle") {
                        Task { await camera.connector.connectDemo(using: MockCameraTransport(faults: .gfx100WithoutKitchen)) }
                    }
                }
            }
            .disabled(camera.connector.isConnecting)
            .opacity(camera.connector.isConnecting ? 0.45 : 1)
            .themedCard(cornerRadius: 16)
            Text(diagnosticMode
                 ? "No Fuji body handy? “Connect Demo Camera” runs the full read/import/push workflow with a simulated camera. For real hardware, connect by USB in “USB RAW Conv./Backup Restore” mode — see Connection Help."
                 : "Connect your camera by USB in “USB RAW Conv./Backup Restore” mode — see Connection Help.")
                .font(.caption)
                .foregroundStyle(Theme.ink3)
                .padding(.horizontal, 4)
        }
    }

    private func connectRow(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.ink3)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Diagnostics: what the camera says it holds and will accept, per property. Lives here rather
    /// than in Settings because it needs the live session (see `CameraPropertyReportView`).
    private var propertyReportButton: some View {
        Button { showingPropertyReport = true } label: {
            Label("Camera Property Report", systemImage: "list.bullet.rectangle")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.ink2)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .buttonStyle(.plain)
    }

    /// Diagnostics: the connect/disconnect/keepalive/recovery event history (`CameraLog`). Shown
    /// outside the `isConnected` gate on purpose — see the call site.
    private var connectionLogButton: some View {
        Button { showingConnectionLog = true } label: {
            Label("Connection Log", systemImage: "text.alignleft")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.ink2)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .buttonStyle(.plain)
    }

    private var helpButton: some View {
        Button { showingGuide = true } label: {
            Label("Connection Help & Requirements", systemImage: "questionmark.circle")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
}
