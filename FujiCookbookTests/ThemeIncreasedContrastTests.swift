import SwiftUI
import UIKit
import XCTest
@testable import FujiCookbook

/// Increase Contrast raises secondary and tertiary text and the hairline to their targets on every
/// surface, in both appearances, and leaves every other token as it is. The colors are resolved
/// against trait collections, so no Simulator setting is involved.
final class ThemeIncreasedContrastTests: XCTestCase {

    private static let appearances: [UIUserInterfaceStyle] = [.light, .dark]
    private static let surfaces: [(name: String, color: Color)] = [
        ("paper", Theme.paper), ("paper2", Theme.paper2), ("card", Theme.card),
    ]

    private func resolve(_ color: Color, _ style: UIUserInterfaceStyle,
                         _ contrast: UIAccessibilityContrast) -> UIColor {
        let traits = UITraitCollection { traits in
            traits.userInterfaceStyle = style
            traits.accessibilityContrast = contrast
        }
        return UIColor(color).resolvedColor(with: traits)
    }

    private func assertContrast(of token: Color, named name: String, atLeast target: Double,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        for style in Self.appearances {
            for surface in Self.surfaces {
                let ratio = try WCAGContrast.ratio(resolve(token, style, .high),
                                                   resolve(surface.color, style, .high))
                XCTAssertGreaterThanOrEqual(ratio, target, "\(name) on \(surface.name), \(style)",
                                            file: file, line: line)
            }
        }
    }

    func testSecondaryTextReachesSevenToOneOnEverySurface() throws {
        try assertContrast(of: Theme.ink2, named: "ink2", atLeast: 7)
    }

    func testTertiaryTextReachesFourAndAHalfToOneOnEverySurface() throws {
        try assertContrast(of: Theme.ink3, named: "ink3", atLeast: 4.5)
    }

    func testHairlineReachesOneAndAHalfToOneAgainstCard() throws {
        for style in Self.appearances {
            let ratio = try WCAGContrast.ratio(resolve(Theme.line, style, .high),
                                               resolve(Theme.card, style, .high))
            XCTAssertGreaterThanOrEqual(ratio, 1.5, "line on card, \(style)")
        }
    }

    func testEveryOtherTokenKeepsItsNormalValue() {
        let unchanged: [(name: String, color: Color)] = [
            ("paper", Theme.paper), ("paper2", Theme.paper2), ("card", Theme.card), ("ink", Theme.ink),
            ("accent", Theme.accent), ("onAccent", Theme.onAccent), ("liveDot", Theme.liveDot),
            ("accentSoft", Theme.accentSoft), ("amber", Theme.amber), ("onAmber", Theme.onAmber),
            ("amberSoft", Theme.amberSoft), ("star", Theme.star), ("warning", Theme.warning),
        ]
        for style in Self.appearances {
            for token in unchanged {
                XCTAssertEqual(resolve(token.color, style, .high), resolve(token.color, style, .normal),
                               "\(token.name), \(style)")
            }
        }
    }

    func testOnlyHighContrastChangesTheRaisedTokens() {
        for style in Self.appearances {
            for token in [Theme.ink2, Theme.ink3, Theme.line] {
                XCTAssertNotEqual(resolve(token, style, .high), resolve(token, style, .normal))
                XCTAssertEqual(resolve(token, style, .normal), resolve(token, style, .unspecified))
            }
        }
    }
}
