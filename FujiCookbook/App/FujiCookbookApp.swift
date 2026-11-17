import SwiftUI
import SwiftData

@main
struct FujiCookbookApp: App {
    /// Single SwiftData store for the inventory.
    let modelContainer: ModelContainer

    /// Surfaced in Settings so the user can confirm sync is active, and so a silent fallback is
    /// diagnosable instead of a mysterious "Local only".
    private let cloudStoreState: CloudStoreState

    /// Drives the session-termination marker and the log flush — see the `onChange` in `body`.
    @Environment(\.scenePhase) private var scenePhase

    @State private var camera = CameraServices()
    @State private var importCoordinator = ImportCoordinator()
    @State private var aiSettings = AISettings()
    @State private var ownedCameras = OwnedCameras()
    private let photoLibrary = PhotoKitLibrary()

    /// Light, Dark or System, from Settings ▸ Display — applied to every window below.
    @AppStorage(AppearancePreference.key, store: SharedDefaults.suite)
    private var appearance: AppearancePreference = .system

    /// UserDefaults key for the opt-in iCloud sync preference (off by default). Read at launch to pick
    /// the store configuration; also bound by the Settings toggle.
    static let iCloudSyncKey = "icloud.sync.enabled"

    /// A silent CloudKit push launches the app with no scene (`UIBackgroundModes` in Info.plist), and
    /// `applicationState` is `.background` from the first instruction of such a launch; a person
    /// opening the app starts it `.inactive`.
    private static var launchContext: SessionTermination.LaunchContext {
        UIApplication.shared.applicationState == .background ? .background : .foreground
    }

    init() {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--initialize-cloudkit-schema") {
            CloudKitSchemaInitializer.runAndExit()
        }
#endif
        // Roll before anything logs, so `previous.log` is the run that just ended; detection then
        // copies it somewhere that never rolls.
        let rolledLogs = AppLog.rollLogFiles()
        SessionTermination.detectAtLaunch(Self.launchContext, after: rolledLogs)
        AppLog.info(.app, "Launch — \(BuildChannel.current.rawValue) build")
        // On disk now, so every run has a `current.log` of its own: a run that dies before its first
        // flush otherwise leaves none, and the next launch has nothing to preserve. One small
        // synchronous write — the file was rolled away a moment ago.
        AppLog.flushNow()
        Theme.applyAppearance()
        PickedRAFStore.purge()
        AISettings.purgeRetiredProviderData()
        let dropped = ScreenshotInbox.purgeStale()
        if dropped > 0 { AppLog.info(.share, "Dropped \(dropped) stale shared screenshot(s)") }
        // The store lives in the App Group so the Share Extension can write recipes straight into
        // the library — see `SharedModelStore`, the single definition of both the schema and the
        // configuration, so the two processes cannot drift apart.
        // The store configuration is fixed when it's created here, so toggling the preference only
        // takes effect on the next launch.
        let wantsCloud = UserDefaults.standard.bool(forKey: Self.iCloudSyncKey)
        let opened: OpenedStore<ModelContainer>
        do {
            opened = try OpenedStore.open(wantsCloud: wantsCloud) { cloudKit in
                try ModelContainer(for: SharedModelStore.schema,
                                   configurations: SharedModelStore.configuration(cloudKit: cloudKit))
            }
        } catch {
            fatalError("Failed to create the recipe store: \(error)")
        }
        modelContainer = opened.store
        cloudStoreState = opened.state
        ScanConfiguration.publishStoreMode(cloudKit: opened.state.isCloudKit)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(Theme.accent)
                // On the windows rather than through `.preferredColorScheme`: going back to System
                // through that modifier leaves an open sheet — Settings itself — in the old style.
                .onChange(of: appearance, initial: true) { _, choice in
                    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                        scene.windows.forEach { $0.overrideUserInterfaceStyle = choice.interfaceStyle }
                    }
                }
                .environment(camera)
                .environment(importCoordinator)
                .environment(aiSettings)
                .environment(ownedCameras)
                .environment(\.photoLibrary, photoLibrary)
                .environment(\.cloudStoreState, cloudStoreState)
                // Open .fujirecipe / .json files from Files, Mail, Messages, the share sheet.
                .onOpenURL { url in
                    importCoordinator.load(url: url)
                }
                .onChange(of: scenePhase) { _, phase in
                    // The marker tracks *foreground presence*, not process lifetime. iOS terminating
                    // a suspended app is routine and must not read as a fault, so leaving `.active`
                    // clears it and only a death while the user was looking at the app leaves one
                    // behind. See `SessionTermination`.
                    guard phase != .active else {
                        SessionTermination.markForegroundActive()
                        return
                    }
                    SessionTermination.markForegroundEnded()
                    // Backgrounding is the last reliable moment before iOS may kill the process.
                    AppLog.flush()
                }
        }
        .modelContainer(modelContainer)
    }
}
