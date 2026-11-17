import UIKit

/// WCAG 2.x contrast between two opaque colors: the lighter relative luminance over the darker,
/// each plus 0.05. Relative luminance weights the linearised sRGB channels.
enum WCAGContrast {
    struct NotRGB: Error {}

    static func ratio(_ first: UIColor, _ second: UIColor) throws -> Double {
        let luminances = [try relativeLuminance(first), try relativeLuminance(second)].sorted()
        return (luminances[1] + 0.05) / (luminances[0] + 0.05)
    }

    static func relativeLuminance(_ color: UIColor) throws -> Double {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { throw NotRGB() }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    private static func linear(_ channel: CGFloat) -> Double {
        let value = Double(channel)
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}
