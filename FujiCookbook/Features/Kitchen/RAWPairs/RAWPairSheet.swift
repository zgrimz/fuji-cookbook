import SwiftUI

extension View {
    /// Choose RAW+JPEG Photos: the sheet that reads the RAF a RAW+JPEG photo keeps behind its JPEG.
    ///
    /// Under full access the regular picker reads pairs itself, so `onFullAccess` opens it instead
    /// of the sheet. `onPick` receives the chosen photos' identifiers in tap order; `onBrowseFiles`
    /// is where a user who can't grant access is sent.
    func rawPairPicker(isPresented: Binding<Bool>, limit: Int?,
                       onPick: @escaping ([String]) -> Void,
                       onFullAccess: @escaping () -> Void,
                       onBrowseFiles: @escaping () -> Void) -> some View {
        modifier(RAWPairPickerPresenter(isPresented: isPresented, limit: limit,
                                        actions: .init(pick: onPick, fullAccess: onFullAccess,
                                                       browseFiles: onBrowseFiles)))
    }
}

private struct RAWPairPickerPresenter: ViewModifier {
    struct Actions {
        let pick: ([String]) -> Void
        let fullAccess: () -> Void
        let browseFiles: () -> Void
    }

    @Binding var isPresented: Bool
    let limit: Int?
    let actions: Actions

    @Environment(\.photoLibrary) private var library
    @State private var model: RAWPairPickerModel?
    @State private var pendingOutcome: RAWPairPickerModel.Outcome?

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, presented in
                guard presented else { return }
                if RAWPairRoute(library.access) == .photoPicker {
                    isPresented = false
                    actions.fullAccess()
                } else {
                    model = RAWPairPickerModel(library: library, limit: limit)
                }
            }
            .sheet(item: $model, onDismiss: finish) { model in
                RAWPairSheet(model: model)
            }
            .onChange(of: model?.outcome) { _, outcome in
                guard let outcome else { return }
                pendingOutcome = outcome
                model = nil
            }
    }

    /// Acts on what the sheet ended with once it has gone, so a picker opened in response never
    /// collides with the sheet's dismissal.
    private func finish() {
        isPresented = false
        guard let outcome = pendingOutcome else { return }
        pendingOutcome = nil
        switch outcome {
        case .picked(let ids): actions.pick(ids)
        case .useRegularPicker: actions.fullAccess()
        case .browseFiles: actions.browseFiles()
        }
    }
}

/// The sheet's one navigation stack, so the explainer gives way to the photos without a second
/// sheet sliding up.
private struct RAWPairSheet: View {
    let model: RAWPairPickerModel

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                switch model.screen {
                case .explainer: RAWPairExplainer(model: model)
                case .sharedPhotos: SharedRAWPhotosView(model: model)
                case .accessDenied: RAWPairAccessDenied(model: model)
                case .accessRestricted: RAWPairAccessRestricted(model: model)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .background(Theme.paper)
        .task(id: model.accessRequests) {
            guard model.accessRequests > 0 else { return }
            await model.requestAccess()
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await model.refreshAccess()
        }
    }
}

/// The sentence every access screen opens with: why the picker can't give the RAW. The button's
/// name is bold, as every control named on these screens is, so it doesn't read as a verb phrase.
private let pickerOnlySharesTheJPEG = "Apple Photos bundles RAW+JPEG pairs into one photo, and **Choose from Photos** only receives the JPEG."

/// Before the system prompt, which iOS shows once: what the app wants, why the picker can't give
/// it, and which button to press.
private struct RAWPairExplainer: View {
    let model: RAWPairPickerModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        RAWPairAccessLayout(illustration: .open,
                            title: "Get the RAW,\nNot Just the JPEG",
                            message: [pickerOnlySharesTheJPEG,
                                      "To pull the RAW file behind it, Fuji Cookbook needs access to your photos."]) {
            InstructionRow(systemImage: "hand.tap", text: "On the next screen, choose **Limit Access** or **Allow Full Access**.")
            InstructionRow(systemImage: "eye", text: "The app only reads what you select, and sends it only to your camera.")
            InstructionRow(systemImage: "gearshape", text: "Change your access anytime in Settings.")
        } actions: {
            GuidedPrimaryButton(title: "Continue", busy: model.isRequestingAccess) {
                model.askForAccess()
            }
            GuidedSecondaryButton(title: "Not Now") { dismiss() }
        }
    }
}

/// Access refused: why the app asks, the way back through Settings, and the way around.
private struct RAWPairAccessDenied: View {
    let model: RAWPairPickerModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        RAWPairAccessLayout(illustration: .locked,
                            title: "Photo Access Is Off",
                            message: [pickerOnlySharesTheJPEG,
                                      "To pull the RAW file behind it, Fuji Cookbook needs access to your photos."],
                            note: "Come back here afterwards and your photos will be ready to choose.") {
            InstructionRow(systemImage: "gearshape", text: "Tap **Open Settings** below.")
            InstructionRow(systemImage: "photo", text: "Tap **Photos**.")
            InstructionRow(systemImage: "checkmark.circle", text: "Choose **Limited Access** or **Full Access**.")
        } actions: {
            GuidedPrimaryButton(title: "Open Settings", systemImage: "gearshape") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            Button("Browse Files…") { model.useBrowseFiles() }
                .buttonStyle(.outline)
            GuidedSecondaryButton(title: "Not Now") { dismiss() }
        }
    }
}

/// Access the user can't grant: why the app asks, and the way around.
private struct RAWPairAccessRestricted: View {
    let model: RAWPairPickerModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        RAWPairAccessLayout(illustration: .locked,
                            title: "Photo Access Isn't Available",
                            message: [pickerOnlySharesTheJPEG,
                                      "Pulling the RAW file behind it needs access to your photos, which restrictions on this device don't allow."],
                            note: "You can still bring in the .RAF file itself with Browse Files.") {
            EmptyView()
        } actions: {
            GuidedPrimaryButton(title: "Browse Files…", systemImage: "folder") { model.useBrowseFiles() }
            GuidedSecondaryButton(title: "Done") { dismiss() }
        }
    }
}

/// The shape every access screen shares, so the explainer and the way back read as one story:
/// the two-file illustration, a title, why the app asks, a card of steps, and the actions pinned
/// to the bottom. It scrolls, so large text never pushes the actions off screen.
private struct RAWPairAccessLayout<Steps: View, Actions: View>: View {
    let illustration: RAWPairIllustration.RAWAccess
    let title: String
    /// Short paragraphs: why the picker falls short, then what the app needs. Markdown bold marks a
    /// control's name.
    let message: [String]
    var note: String?
    @ViewBuilder let steps: Steps
    @ViewBuilder let actions: Actions

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                RAWPairIllustration(state: illustration)
                    .padding(.top, 12)
                VStack(spacing: 12) {
                    Text(title)
                        .font(Theme.serif(26))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.ink)
                    VStack(spacing: 8) {
                        ForEach(message, id: \.self) { paragraph in
                            Text(LocalizedStringKey(paragraph))
                        }
                    }
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.ink2)
                }
                if Steps.self != EmptyView.self {
                    VStack(alignment: .leading, spacing: 14) { steps }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .themedCard()
                }
                if let note {
                    Text(note)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.ink2)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Theme.paper)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) { actions }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .background(Theme.paper)
        }
    }
}

/// One line in an access screen's card: an accent symbol and a sentence, with the system's
/// button names in bold.
private struct InstructionRow: View {
    let systemImage: String
    let text: LocalizedStringKey

    var body: some View {
        Label {
            Text(text).foregroundStyle(Theme.ink)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
        }
        .font(.subheadline)
    }
}

/// One photo, two files: the JPEG and the RAW fanned side by side, overlapping only at the edge
/// so both labels read. Locked, the RAW card carries a padlock: the file the app can't reach yet.
private struct RAWPairIllustration: View {
    enum RAWAccess {
        case open
        case locked
    }

    let state: RAWAccess

    var body: some View {
        ZStack {
            card(label: "RAW", systemImage: "camera.aperture", fill: Theme.amberSoft, tint: Theme.amber)
                .overlay(alignment: .topTrailing) {
                    if state == .locked { lockBadge }
                }
                .rotationEffect(.degrees(7))
                .offset(x: 46, y: 4)
            card(label: "JPEG", systemImage: "photo", fill: Theme.accentSoft, tint: Theme.accent)
                .rotationEffect(.degrees(-7))
                .offset(x: -46, y: 4)
        }
        .frame(height: 150)
        .accessibilityHidden(true)
    }

    private func card(label: String, systemImage: String, fill: Color, tint: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .regular))
            Text(label)
                .font(.caption.weight(.bold))
                .tracking(1)
        }
        .foregroundStyle(tint)
        .frame(width: 104, height: 124)
        .background(fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
    }

    private var lockBadge: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Theme.ink2, in: Circle())
            .overlay(Circle().strokeBorder(Theme.paper, lineWidth: 2))
            .offset(x: 10, y: -10)
    }
}
