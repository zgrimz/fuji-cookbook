import SwiftUI
import UIKit
import XCTest
@testable import FujiCookbook

/// The connected-camera card's text and live dot read on its `accentSurface` fill in both
/// appearances, and in dark mode the surface stays a deep green rather than the light `accent`.
final class ThemeAccentSurfaceTests: XCTestCase {

    private static let appearances: [UIUserInterfaceStyle] = [.light, .dark]

    private func resolve(_ color: Color, _ style: UIUserInterfaceStyle) -> UIColor {
        UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
    }

    private func ratio(_ foreground: Color, on background: Color, _ style: UIUserInterfaceStyle) throws -> Double {
        try WCAGContrast.ratio(resolve(foreground, style), resolve(background, style))
    }

    func testCardTextReachesFourAndAHalfToOne() throws {
        for style in Self.appearances {
            let measured = try ratio(Theme.onAccentSurface, on: Theme.accentSurface, style)
            XCTAssertGreaterThanOrEqual(measured, 4.5, "onAccentSurface on accentSurface, \(style)")
        }
    }

    func testLiveDotReachesThreeToOne() throws {
        for style in Self.appearances {
            let measured = try ratio(Theme.liveDot, on: Theme.accentSurface, style)
            XCTAssertGreaterThanOrEqual(measured, 3, "liveDot on accentSurface, \(style)")
        }
    }

    func testDarkSurfaceIsDeeperThanTheDarkAccent() throws {
        let surface = try WCAGContrast.relativeLuminance(resolve(Theme.accentSurface, .dark))
        let accent = try WCAGContrast.relativeLuminance(resolve(Theme.accent, .dark))
        XCTAssertLessThan(surface, accent / 2)
    }
}
