import SwiftUI
import UIKit

extension View {
    /// Shows `message` briefly at the top of the screen and clears it, for an action that worked
    /// and needs no answer: an alert for "Saved to Photos" stops the person who is mid-way through
    /// comparing photos. VoiceOver announces the message. Errors still belong in an alert.
    func confirmationToast(_ message: Binding<String?>) -> some View {
        modifier(ConfirmationToast(message: message))
    }
}

private struct ConfirmationToast: ViewModifier {
    @Binding var message: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let visibleFor: Duration = .seconds(2)

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let message {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .labelStyle(ToastLabelStyle())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Theme.card, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.line))
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                        .padding(.top, 8)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                        .accessibilityHidden(true)
                        .task(id: message) {
                            UIAccessibility.post(notification: .announcement, argument: message)
                            try? await Task.sleep(for: Self.visibleFor)
                            self.message = nil
                        }
                }
            }
            .animation(.easeOut(duration: 0.25), value: message)
    }
}

private struct ToastLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(Theme.accent)
            configuration.title
        }
    }
}
