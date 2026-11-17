import XCTest
@testable import FujiCookbook

/// `resolveLayout` over the blob shapes cameras actually produce.
///
/// The canonical-base rule is the correction `FujiRawConvProfile`'s own header is written around,
/// and the demo's single 625/29 shape arriving through a cook test doesn't exercise it: the shape a
/// GFX body produces (the 2026-09-17 GFX100S harvest) is not the shape the mock hands back, and a
/// registry entry was turned on off the strength of it resolving.
///
/// Camera facts in these tests are from zgrimz/fujifilm-ptp-reference:
/// `docs/06-conversion-profile.md#lengths-seen`,
/// `docs/06-conversion-profile.md#numparams-means-different-things-in-each-direction`,
/// `docs/06-conversion-profile.md#parsing-safely`, `docs/06-conversion-profile.md#the-host-write-form`, and
/// `docs/03-encodings.md#0xd190-dynamic-range`.
final class RawConvLayoutTests: XCTestCase {

    /// The Demo Camera's profile is the X-T50's shape and IOPCode, not one from a body nobody has
    /// identified.
    func testTheDemoProfileIsTheXT50s() {
        let blob = FujiRawConvProfile.demoBaseProfile()
        XCTAssertEqual(blob.count, 625)
        XCTAssertEqual(FujiRawConvProfile.numParams(in: blob), 29)
        XCTAssertEqual(FujiRawConvProfile.iopCode(in: blob), "FF189504")
    }

    /// The GFX100S's own profile (2026-09-17, fw 2.13): 621 bytes, 28 params, IOPCode FF149502,
    /// base 0x1FD. Asserted rather than assumed, because enabling that body's Kitchen rests on it.
    func testTheGFXProfileResolvesAtTheCanonicalBase() throws {
        let blob = FujiRawConvProfile.demoGFXBaseProfile()
        XCTAssertEqual(blob.count, 621)
        XCTAssertEqual(FujiRawConvProfile.numParams(in: blob), 28)
        XCTAssertEqual(FujiRawConvProfile.iopCode(in: blob), "FF149502")

        let layout = try XCTUnwrap(FujiRawConvProfile.resolveLayout(blob))
        XCTAssertEqual(layout.base, FujiRawConvProfile.canonicalBase, "0x1FD, as the body reported")
        XCTAssertEqual(layout.numParams, 28)
        XCTAssertEqual(FujiRawConvProfile.tailBase(of: blob), FujiRawConvProfile.canonicalBase,
                       "a camera read's tail agrees; it is the host write that doesn't")

        let decoded = FujiRawConvProfile.decode(blob, layout: layout)
        XCTAssertEqual(decoded.filmSimulation, .provia)
        XCTAssertEqual(decoded.dynamicRange, .dr100, "DR=100 and PROVIA are the two strong signals")
    }

    /// The diagnostic the harvest files is the evidence a body gets enabled on, so its shape is part
    /// of the contract: three candidates, the canonical one taken, the other two rejected. This is
    /// the synthetic twin of what the GFX100S report actually printed.
    func testTheDiagnosticNamesTheThreeCandidatesTheHarvestReported() {
        let diagnostic = FujiRawConvProfile.layoutDiagnostic(FujiRawConvProfile.demoGFXBaseProfile())
        XCTAssertTrue(diagnostic.contains("621 bytes / 28 params / IOPCode FF149502"), diagnostic)
        XCTAssertTrue(diagnostic.contains("canonical base 0x1FD, tail base 0x1FD"), diagnostic)
        XCTAssertTrue(diagnostic.contains("base 0x1FD:"), diagnostic)
        XCTAssertTrue(diagnostic.contains("base 0x201:"), diagnostic)
        XCTAssertTrue(diagnostic.contains("base 0x1F9:"), diagnostic)
        XCTAssertFalse(diagnostic.contains("no candidate base"), diagnostic)
    }

    /// Every camera-read shape seen on any body lands on the same base — 601/23 (X-H1), 621/28
    /// (X-Pro3 and GFX100S) and 625/29 (X-T50). That is the claim the header makes and nothing
    /// checked, and it is why `supportsRawConversion` can be decided per body rather than per
    /// generation.
    func testEveryReadShapeLandsOnTheSameBase() throws {
        for blob in [FujiRawConvProfile.demoShortBaseProfile(),
                     FujiRawConvProfile.demoGFXBaseProfile(),
                     FujiRawConvProfile.demoBaseProfile()] {
            let layout = try XCTUnwrap(FujiRawConvProfile.resolveLayout(blob), "\(blob.count) bytes")
            XCTAssertEqual(layout.base, FujiRawConvProfile.canonicalBase, "\(blob.count) bytes")
        }
    }

    /// The asymmetry the canonical-base rule exists for: a host write's own tail says 0x201 because
    /// X RAW Studio counts 29 for a 30-cell blob, and the canonical base still wins. That mismatch
    /// is the entire origin of the old 0x1FD-vs-0x201 dispute.
    func testAHostWriteStillResolvesAtTheCanonicalBase() throws {
        let wire = FujiRawConvProfile.hostWriteForm(FujiRawConvProfile.demoGFXBaseProfile())
        XCTAssertEqual(wire.count, FujiRawConvProfile.hostWriteLength)
        XCTAssertEqual(FujiRawConvProfile.tailBase(of: wire), 0x201, "the tail lands one cell late")
        XCTAssertEqual(try XCTUnwrap(FujiRawConvProfile.resolveLayout(wire)).base,
                       FujiRawConvProfile.canonicalBase)
    }
}

/// The D190 write probe's candidate list, and that the probe drives it the same way the grain one
/// is driven. A GFX100S and an X-T50 both answered `0x201C` to a DR400 push (2026-09-17), and the
/// report needs to be able to say why: Fujifilm gates DR200/DR400 on the slot's own ISO and blocks
/// Dynamic Range entirely under D-Range Priority. No bank-ISO read is characterized; the priority
/// is readable at D191 (zgrimz/fujifilm-ptp-reference `docs/04-custom-slots.md#iso-gating`,
/// `docs/03-encodings.md#0xd191-d-range-priority`).
@MainActor
final class DynamicRangeProbeTests: XCTestCase {

    private var candidates: [Int] { CameraDiagnostics.dynamicRangeProbeCandidates }

    /// The list is the instrument, so its shape is the contract: every DR the app can encode, the
    /// Auto sentinel, and DR100 interleaved as the control that separates "this value is refused"
    /// from "this slot stopped taking writes".
    func testTheCandidateListCoversEveryDRAndInterleavesTheControl() {
        XCTAssertEqual(candidates, [100, 200, 100, 400, 100, FujiEncoding.drAutoSlotValue])

        for percent in FujiEncoding.drToPercent.values {
            XCTAssertTrue(candidates.contains(percent), "DR\(percent) is one the app can encode")
        }
        XCTAssertTrue(candidates.contains(FujiEncoding.drAutoSlotValue),
                      "Auto has no ISO floor, so it is what proves a floor is what refused the rest")
        XCTAssertEqual(candidates.first, 100, "the control goes first")
        for (i, value) in candidates.enumerated() where value == 200 || value == 400 {
            XCTAssertEqual(candidates[i - 1], 100, "every gated value is preceded by the control")
        }
    }

    /// `-1` reaches the wire as `0xFFFF`, which is the only reason Auto can be probed at all —
    /// `packU16` truncates rather than clamping.
    func testAutoPacksAsTheSentinelTheCameraExpects() {
        XCTAssertEqual(FujiEncoding.packU16(FujiEncoding.drAutoSlotValue), Data([0xFF, 0xFF]))
        XCTAssertEqual(FujiEncoding.decodeInt16(Data([0xFF, 0xFF])), FujiEncoding.drAutoSlotValue)
    }

    /// End to end against the mock: one write per candidate, plus the restore, all in the trace.
    func testTheProbeWritesEveryCandidateAndPutsTheValueBack() async throws {
        let m = CameraServices()
        await m.connector.connectDemo(using: MockCameraTransport(faults: MockCameraFaults(isInstant: true)))

        let entries = try await m.diagnostics.probeWriteValues(slot: 1, property: .dynamicRange, candidates: candidates)
        XCTAssertEqual(entries.map(\.wrote), candidates)

        let writes = (m.reports.report?.transactions ?? []).filter {
            $0.operation == "0x1016" && $0.parameters.first == "0xD190"
        }
        XCTAssertEqual(writes.count, candidates.count + 1,
                       "every candidate plus the restore — the probe must not leave the slot changed")
    }
}

/// Property codes are spelled the way the property tables spell them — but only where that spelling
/// is true. The first non-vendor property this app read (2026-09-18) came back on a report labelled
/// `D00F`: `0x500F` masked with `0x0FFF` and prefixed `D`, which is a Fuji vendor code that does
/// not exist.
final class PropertyLabelTests: XCTestCase {

    func testVendorCodesKeepTheirShorthand() {
        XCTAssertEqual(PTPHex.propertyLabel(0xD19D), "D19D")
        XCTAssertEqual(PTPHex.propertyLabel(0xD190), "D190")
        XCTAssertEqual(PTPHex.propertyLabel(0xD185), "D185")
        for prop in FujiPTP.PresetProp.allCases {
            XCTAssertEqual(PTPHex.propertyLabel(prop.rawValue),
                           String(format: "D%03X", prop.rawValue & 0x0FFF),
                           "every preset property is in the vendor range and keeps the short form")
        }
    }

    /// The bug, in the one case that produced it.
    func testAStandardPropertyIsSpelledInFull() {
        XCTAssertEqual(PTPHex.propertyLabel(FujiPTP.Prop.exposureIndex), "0x500F")
        XCTAssertNotEqual(PTPHex.propertyLabel(FujiPTP.Prop.exposureIndex), "D00F",
                          "masking a standard code into the vendor range invents a property")
        XCTAssertEqual(PTPHex.propertyLabel(0x5001), "0x5001")
    }
}
