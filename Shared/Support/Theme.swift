import SwiftUI
import UIKit

/// The app-wide design system: warm paper surfaces, a serif for recipe names (the cookbook
/// metaphor), a deep green accent, and amber for the Kitchen's "cook" actions. Every palette color
/// has its own light and dark value.
enum Theme {

    // MARK: Palette

    /// Screen background — warm paper.
    static let paper = dynamic(light: 0xF4EFE4, dark: 0x1C1914)
    /// Inset surface (search fields, chip backgrounds, empty slots) — slightly deeper paper.
    static let paper2 = dynamic(light: 0xEFE8DA, dark: 0x28231B)
    /// Elevated card surface.
    static let card = dynamic(light: 0xFFFFFF, dark: 0x2E2921)
    /// Primary text.
    static let ink = dynamic(light: 0x201D17, dark: 0xF0EADC)
    /// Secondary text.
    static let ink2 = dynamic(light: 0x6E675A, dark: 0xB3AA97)
    /// Tertiary text / disabled.
    static let ink3 = dynamic(light: 0xA49C8A, dark: 0x7D7565)
    /// Hairlines and card borders.
    static let line = dynamic(light: 0xE7DFCF, dark: 0x3B342A)
    /// Primary accent — deep cookbook green.
    static let accent = dynamic(light: 0x2E6B4A, dark: 0x76BC93)
    /// Text and symbols on an `accent` fill. White on the light green, dark on the dark-mode green,
    /// which is too light to carry white: white on it measures about 2.2:1, under the 3:1 large
    /// text needs; this measures about 7.8:1, and white on the light green about 6.3:1.
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x1C1914)
    /// The connected camera's live dot on an `accent` fill: a pale green on the light accent, a deep
    /// one on the dark-mode accent, so the dot clears the 3:1 a state graphic needs in both (about
    /// 4.2:1 and 3.9:1). A pale dot on the dark-mode accent measures about 1.5:1.
    static let liveDot = dynamic(light: 0x8FE3B0, dark: 0x24543A)
    /// Soft accent fill (filled slot badges, selected states).
    static let accentSoft = dynamic(light: 0xE4EFE6, dark: 0x24382C)
    /// The Kitchen's "cook" amber.
    static let amber = dynamic(light: 0xB87A33, dark: 0xD2954C)
    /// Soft amber fill.
    static let amberSoft = dynamic(light: 0xF3E7D2, dark: 0x3C2F1D)
    /// Favorite star.
    static let star = amber
    /// Caution: what the app couldn't read, write, verify or finish, and a field that doesn't
    /// match the one it is compared with. The palette's warning orange, deepened in light mode:
    /// the dark-mode orange there measures about 2.3:1 on paper, under the 4.5:1 caption text needs;
    /// this measures 4.5:1 or more on paper, paper2 and card. Amber stays the Kitchen's cook actions
    /// and the star, so a caution never reads as a button.
    static let warning = dynamic(light: 0x985917, dark: 0xE08C34)
    /// The fill behind a warning card or badge, as soft green and soft amber are for theirs.
    static let warningSoft = warning.opacity(0.12)

    // MARK: Type

    /// Serif face for recipe/chapter names and screen titles (the "cookbook" voice).
    static func serif(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Compact all-caps section label, e.g. "ALL PARAMETERS".
    struct SectionLabel: View {
        let text: String
        init(_ text: String) { self.text = text }
        var body: some View {
            Text(text.uppercased())
                .font(.caption.weight(.semibold))
                .kerning(1.2)
                .foregroundStyle(Theme.ink3)
        }
    }

    /// Numbered step header ("① RAW files") — the Kitchen's develop flow reads as a task of three
    /// steps, not a settings screen.
    struct StepHeader: View {
        let number: Int
        let title: String

        var body: some View {
            HStack(spacing: 10) {
                Text("\(number)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.accent))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Step \(number): \(title)")
        }
    }

    // MARK: Global appearance

    /// Serif navigation titles, applied once at launch. Weight is baked into the base font so the
    /// serif design descriptor keeps it.
    static func applyAppearance() {
        var serifLarge: UIFont?
        var serifInline: UIFont?
        if let large = UIFont.systemFont(ofSize: 34, weight: .semibold).fontDescriptor.withDesign(.serif) {
            serifLarge = UIFont(descriptor: large, size: 34)
        }
        if let inline = UIFont.systemFont(ofSize: 17, weight: .semibold).fontDescriptor.withDesign(.serif) {
            serifInline = UIFont(descriptor: inline, size: 17)
        }

        // Blurred bar once content scrolls under it…
        let standard = UINavigationBarAppearance()
        standard.configureWithDefaultBackground()
        // …but transparent at rest so the warm paper runs behind the large title.
        let scrollEdge = UINavigationBarAppearance()
        scrollEdge.configureWithTransparentBackground()
        for appearance in [standard, scrollEdge] {
            if let serifLarge { appearance.largeTitleTextAttributes = [.font: serifLarge] }
            if let serifInline { appearance.titleTextAttributes = [.font: serifInline] }
        }
        UINavigationBar.appearance().standardAppearance = standard
        UINavigationBar.appearance().scrollEdgeAppearance = scrollEdge
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255,
                  alpha: 1)
    }
}

// MARK: - Film simulation swatches

extension FilmSimulation {
    /// The family swatch color shown next to a recipe's film simulation — one hue per family so a
    /// library scans by look: golds for Classic Chrome, warm ambers for the Neg films, cool grays
    /// for monochrome, teal for cinema.
    var swatchColor: Color {
        switch self {
        case .provia: return Color(red: 0.42, green: 0.48, blue: 0.56)
        case .velvia: return Color(red: 0.69, green: 0.29, blue: 0.27)
        case .astia: return Color(red: 0.35, green: 0.53, blue: 0.66)
        case .classicChrome: return Color(red: 0.60, green: 0.48, blue: 0.25)
        case .proNegHi: return Color(red: 0.72, green: 0.51, blue: 0.44)
        case .proNegStd: return Color(red: 0.65, green: 0.55, blue: 0.50)
        case .classicNeg: return Color(red: 0.66, green: 0.42, blue: 0.26)
        case .nostalgicNeg: return Color(red: 0.78, green: 0.58, blue: 0.33)
        case .eterna: return Color(red: 0.37, green: 0.48, blue: 0.43)
        case .eternaBleachBypass: return Color(red: 0.49, green: 0.54, blue: 0.54)
        case .realaAce: return Color(red: 0.47, green: 0.60, blue: 0.37)
        case .acros, .acrosYe, .acrosR, .acrosG: return Color(red: 0.28, green: 0.28, blue: 0.30)
        case .monochrome, .monochromeYe, .monochromeR, .monochromeG: return Color(red: 0.43, green: 0.43, blue: 0.44)
        case .sepia: return Color(red: 0.66, green: 0.54, blue: 0.42)
        }
    }
}

// MARK: - Components

/// The rounded-square film-sim family swatch.
struct FilmSwatch: View {
    let simulation: FilmSimulation?
    var size: CGFloat = 10

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.36, style: .continuous)
            .fill(simulation?.swatchColor ?? Theme.ink3.opacity(0.4))
            .frame(width: size, height: size)
    }
}

/// One preset colour beside a colour picker: a filled circle, ringed in accent while it is the
/// colour in use. Selection compares resolved colours, so white chosen by the picker still lights
/// the white swatch.
struct SwatchButton: View {
    let color: Color
    let name: String
    let current: Color
    let action: () -> Void

    private var isSelected: Bool { UIColor(current).cgColor == UIColor(color).cgColor }

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(Theme.line))
                .overlay { if isSelected { Circle().strokeBorder(Theme.accent, lineWidth: 2).padding(-3) } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A dense parameter chip ("DR400", "HL −1") — the design system's at-a-glance recipe summary unit.
struct ParamChip: View {
    let text: String
    var prominent = false

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(prominent ? Theme.accentSoft : Theme.paper2,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// A pill-shaped filter chip — filled accent when selected, bordered card when not.
struct FilterChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.footnote.weight(selected ? .semibold : .medium))
                .foregroundStyle(selected ? Theme.onAccent : Theme.ink2)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.card),
                            in: Capsule())
                .overlay { if !selected { Capsule().strokeBorder(Theme.line) } }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Small bordered badge, e.g. the "X-T5" camera tag on a recipe card.
struct BadgeTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(Theme.ink3)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.line))
    }
}

/// The secondary action beside or below a filled one: card fill, hairline border, accent label,
/// full width. Its height matches the filled buttons it sits with, so a pair reads as one row.
///
/// A primitive style so the button inside can stay `.plain` and keep the system's press highlight.
/// Disabled reads at the same 0.45 the filled buttons use.
struct OutlineButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.card)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
                }
        }
        .buttonStyle(.plain)
        .modifier(DimmedWhenDisabled())
    }
}

extension PrimitiveButtonStyle where Self == OutlineButtonStyle {
    static var outline: OutlineButtonStyle { OutlineButtonStyle() }
}

private struct DimmedWhenDisabled: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.opacity(isEnabled ? 1 : 0.45)
    }
}

/// An explicit foreground style replaces the prominent style's own dimmed disabled label, so it is
/// set only while the button is enabled.
private struct OnAccentWhenEnabled: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        if isEnabled {
            content.foregroundStyle(Theme.onAccent)
        } else {
            content
        }
    }
}

/// One setting as a label and its value: the label quiet, the value in ink with aligned digits, so a
/// column of signed numbers lines up. Read as one element by VoiceOver.
struct SettingsRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.ink2)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A recipe's settings as one card of rows, in the order `RecipeSettingsFormatter.rows(for:model:)`
/// gives them. The rule between rows runs the card's full width, like the recipe page's own table.
struct SettingsTable: View {
    let rows: [(field: RecipeField, value: String)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.field) { index, row in
                if index > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                SettingsRow(label: row.field.displayName, value: row.value)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
        }
        .themedCard(cornerRadius: 16)
    }
}

/// Covers the screen while work that mustn't be interrupted runs: a dimmed backdrop that takes every
/// touch, and one card saying what is happening. The card is the app's own, so a wait reads as
/// part of the app rather than a system HUD.
struct BlockingProgressOverlay<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) { content }
                .padding(24)
                .themedCard(cornerRadius: 16)
                .accessibilityElement(children: .combine)
        }
    }
}

extension View {
    /// A blocking overlay with a spinner and one line saying what is happening.
    func blockingProgress(_ label: String, isPresented: Bool) -> some View {
        overlay {
            if isPresented {
                BlockingProgressOverlay {
                    ProgressView()
                    Text(label)
                        .font(.callout)
                        .foregroundStyle(Theme.ink)
                }
            }
        }
    }
}

/// Card chrome shared by every surface in the app: `Theme.card` fill, hairline border, soft shadow.
struct CardBackground: ViewModifier {
    var cornerRadius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .background(Theme.card, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.line))
            .shadow(color: Color(red: 0.16, green: 0.13, blue: 0.06).opacity(0.04), radius: 2, y: 1)
    }
}

extension View {
    /// Apply the design system's card chrome.
    func themedCard(cornerRadius: CGFloat = 18) -> some View {
        modifier(CardBackground(cornerRadius: cornerRadius))
    }

    /// Labels a `.borderedProminent` button in `Theme.onAccent`. The style's white label is unreadable
    /// on the dark-mode accent; a disabled button keeps the style's own grey label.
    func prominentOnAccentLabel() -> some View {
        modifier(OnAccentWhenEnabled())
    }

    /// Style a `List`/`Form` screen with the warm paper background.
    func paperBackground() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.paper)
    }
}

/// Left-aligned wrapping layout for parameter chips.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
