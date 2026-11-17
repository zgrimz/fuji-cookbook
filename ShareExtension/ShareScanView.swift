import SwiftUI

/// The Share Extension's whole screen: scan the shared screenshot, show what came back, save it.
///
/// One stage at a time, in the shape `ReadRecipeView` uses for the same job on the app side — the
/// user is looking at a modal sheet over another app, so anything that isn't the current step is
/// noise.
struct ShareScanView: View {
    @State var model: ShareScanModel

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
            }
            .background(Theme.paper)
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .tint(Theme.accent)
        .task { await model.start() }
    }

    private var title: String {
        switch model.stage {
        case .review(let draft): return draft.isEditing ? "Edit Recipe" : "Recipe Found"
        case .saved(_, let outcome): return outcome == .skipped ? "Skipped" : "Saved"
        default: return "Fuji Cookbook"
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        switch model.stage {
        case .saved, .queued:
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { model.finish(saved: true) }
            }
        case .review(let draft) where draft.isEditing:
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { model.draft?.isEditing = false }
            }
        default:
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { model.finish(saved: false) }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.stage {
        case .loading:
            centered { ProgressView() }

        case .scanning(let image):
            scanning(image)

        case .review(let draft):
            review(draft)

        case .unavailable(let heading, let detail):
            message(title: heading, systemImage: "sparkles", body: detail) {
                primaryButton("Save for Later", systemImage: "tray.and.arrow.down") {
                    model.queueForLater()
                }
            }

        case .failed(let image, let text):
            failed(image: image, message: text)

        case .saveFailed(let draft, let text):
            failed(image: draft.image, message: text)

        case .saved(let name, let outcome):
            // "Saved" would be a lie for a skip — the user chose to keep what they already had, and
            // nothing was written.
            message(title: savedTitle(for: outcome),
                    systemImage: outcome == .skipped ? "checkmark.circle" : "checkmark.circle.fill",
                    body: outcome == .skipped
                        ? "Your existing “\(name)” was left as it is."
                        : "“\(name)” is in your library.") {
                primaryButton("Done", systemImage: nil) { model.finish(saved: true) }
            }
            .task { await dismissAfterConfirmation() }

        case .queued:
            message(title: "Saved for Later",
                    systemImage: "tray.and.arrow.down.fill",
                    body: "Open Fuji Cookbook and this screenshot will be read then.") {
                primaryButton("Done", systemImage: nil) { model.finish(saved: true) }
            }
            .task { await dismissAfterConfirmation() }
        }
    }

    // MARK: Stages

    private func scanning(_ image: UIImage) -> some View {
        VStack(spacing: 20) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 260)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line, lineWidth: 0.5))
            HStack(spacing: 10) {
                ProgressView()
                Text("Sending to \(model.scanProviderName)…")
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink2)
            }
            Text("This screenshot is read by \(model.scanProviderName) using your API key. Fuji Cookbook never receives it.")
                .font(.footnote)
                .foregroundStyle(Theme.ink3)
                .multilineTextAlignment(.center)
            // Stopping saves to the inbox rather than discarding the screenshot: the user asked to
            // import it and only declined to wait. The toolbar's Cancel is the discard.
            Button("Stop and Save for Later") { model.cancelScan() }
                .font(.subheadline)
                .foregroundStyle(Theme.ink2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    @ViewBuilder
    private func review(_ draft: ShareScanModel.Draft) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if draft.isEditing, let binding = Binding($model.draft) {
                ExtractedRecipeEditor(recipe: binding.recipe)
            } else {
                ExtractedRecipeCard(recipe: draft.recipe, image: draft.image)
            }

            if let duplicate = draft.duplicate, let binding = Binding($model.draft) {
                duplicateCard(duplicate, resolution: binding.resolution)
            }

            if !draft.isEditing {
                primaryButton("Save to Library", systemImage: "checkmark") { model.save() }
                Button {
                    model.draft?.isEditing = true
                } label: {
                    Label("Edit First", systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .foregroundStyle(Theme.accent)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 14))
                .buttonStyle(.plain)
            }
        }
    }

    private func duplicateCard(_ match: DuplicateMatch,
                               resolution: Binding<DuplicateResolution>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(match.reason.description, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.warning)
            Text("Already in your library as “\(match.existing.name)”.")
                .font(.footnote)
                .foregroundStyle(Theme.ink2)
            Picker("Duplicate", selection: resolution) {
                ForEach(DuplicateResolution.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .padding(14)
        .themedCard(cornerRadius: 16)
    }

    private func failed(image: UIImage?, message text: String) -> some View {
        VStack(spacing: 16) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .opacity(0.5)
            }
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(Theme.warning)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.ink2)
                .multilineTextAlignment(.center)
            VStack(spacing: 10) {
                primaryButton("Try Again", systemImage: "arrow.clockwise") {
                    Task { await model.retry() }
                }
                Button("Save for Later") { model.queueForLater() }
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    // MARK: Building blocks

    private func message<Actions: View>(title: String, systemImage: String, body text: String,
                                        @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(Theme.serif(24))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.ink2)
                .multilineTextAlignment(.center)
            actions()
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
    }

    private func primaryButton(_ title: String, systemImage: String?,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            .font(.headline)
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func savedTitle(for outcome: RecipeImporter.Outcome) -> String {
        switch outcome {
        case .added: return "Recipe Saved"
        case .replaced: return "Recipe Updated"
        case .skipped: return "Kept Your Version"
        }
    }

    /// Close the sheet on the user's behalf once they've seen the outcome. The button stays for
    /// anyone who'd rather not wait; `finish` is guarded so whichever happens first wins.
    private func dismissAfterConfirmation() async {
        try? await Task.sleep(for: ShareScanModel.confirmationDuration)
        guard !Task.isCancelled else { return }
        model.finish(saved: true)
    }

    private func centered<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack { content() }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
    }
}
