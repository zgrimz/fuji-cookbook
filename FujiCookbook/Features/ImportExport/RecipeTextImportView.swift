import SwiftUI

/// Takes a recipe as pasted or typed text and hands it on for review.
///
/// The clipboard is read only through the system Paste button, so nothing is read until the user
/// taps it and iOS asks no permission. A recipe that reads is passed to `onRead` and the sheet
/// dismisses itself; one that doesn't keeps the text on screen with the reason beside it.
struct RecipeTextImportView: View {
    let onRead: (PastedRecipe) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var failure: (any Error)?
    @FocusState private var editorFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PasteButton(payloadType: String.self) { strings in
                        paste(strings)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                } footer: {
                    Text("Copy a recipe from a website, a forum post or a message, then paste it, or type it below with one setting per line, such as “Highlight: -1”.")
                }
                if let failure {
                    Section { failureLabel(failure) }
                }
                Section("Recipe Text") {
                    TextEditor(text: editableText)
                        .focused($editorFocused)
                        .frame(minHeight: 240)
                        .font(.callout)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityLabel("Recipe text")
                }
            }
            .navigationTitle("Import from Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review") { read() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    /// Typing clears a shown failure, which is about text that is no longer there. A paste sets
    /// `text` directly, so the failure it produces stays.
    private var editableText: Binding<String> {
        Binding(get: { text }, set: { text = $0; failure = nil })
    }

    private func failureLabel(_ failure: any Error) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(failure.localizedDescription)
                if let suggestion = (failure as? LocalizedError)?.recoverySuggestion {
                    Text(suggestion).font(.caption).foregroundStyle(Theme.ink2)
                }
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .foregroundStyle(Theme.warning)
    }

    /// Text too long to read is refused before it replaces what the editor holds.
    private func paste(_ strings: [String]) {
        let pasted = strings.joined(separator: "\n")
        do {
            try RecipeTextParser.checkLength(pasted)
        } catch {
            failure = error
            return
        }
        text = pasted
        read()
    }

    private func read() {
        do {
            onRead(try ImportCoordinator.readPastedText(text))
            dismiss()
        } catch {
            failure = error
            // The failure sits above the editor; lowering the keyboard keeps it in view.
            editorFocused = false
        }
    }
}
