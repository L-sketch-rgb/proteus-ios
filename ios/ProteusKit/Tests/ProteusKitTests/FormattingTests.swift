import XCTest
@testable import ProteusKit

final class FormattingTests: XCTestCase {
    func testTokenFormatting() {
        XCTAssertEqual(Formatting.tokens(nil), "—")
        XCTAssertEqual(Formatting.tokens(0), "0")
        XCTAssertEqual(Formatting.tokens(999), "999")
        XCTAssertEqual(Formatting.tokens(1000), "1.0k")
        XCTAssertEqual(Formatting.tokens(1234), "1.2k")
        XCTAssertEqual(Formatting.tokens(12_345), "12.3k")
        XCTAssertEqual(Formatting.tokens(999_999), "1000.0k")
        XCTAssertEqual(Formatting.tokens(1_000_000), "1.0M")
        XCTAssertEqual(Formatting.tokens(1_200_000), "1.2M")
    }

    func testDurationFormatting() {
        XCTAssertEqual(Formatting.duration(milliseconds: nil), "—")
        XCTAssertEqual(Formatting.duration(seconds: 0), "0:00")
        XCTAssertEqual(Formatting.duration(seconds: 7), "0:07")
        XCTAssertEqual(Formatting.duration(seconds: 65), "1:05")
        XCTAssertEqual(Formatting.duration(seconds: 3725), "1:02:05")
        XCTAssertEqual(Formatting.duration(milliseconds: 7000), "0:07")
        XCTAssertEqual(Formatting.duration(milliseconds: 3_725_000), "1:02:05")
        XCTAssertEqual(Formatting.duration(seconds: -5), "0:00")
    }

    func testUsagePercent() {
        XCTAssertEqual(Formatting.percent(nil), "—")
        XCTAssertEqual(Formatting.percent(UsageWindow(utilization: 0)), "0%")
        XCTAssertEqual(Formatting.percent(UsageWindow(utilization: 0.34)), "34%")
        XCTAssertEqual(Formatting.percent(UsageWindow(utilization: 1)), "100%")
        XCTAssertEqual(Formatting.percent(UsageWindow(utilization: 1.5)), "100%")
    }

    func testISOParsing() {
        XCTAssertNotNil(Formatting.parseISO("2026-11-08T10:00:00Z"))
        XCTAssertNotNil(Formatting.parseISO("2026-11-08T10:00:00.123Z"))
        XCTAssertNil(Formatting.parseISO(""))
        let a = Formatting.parseISO("2026-11-08T10:00:00Z")!
        let b = Formatting.parseISO("2026-11-08T11:00:00Z")!
        XCTAssertEqual(Formatting.elapsedSeconds(sinceISO: "2026-11-08T10:00:00Z", now: b), Int(a.distance(to: b)))
    }

    func testToolSummaryPort() {
        XCTAssertEqual(
            Formatting.toolSummary(name: "Bash", input: .object(["command": .string("swift build\nsecond line")])),
            "swift build"
        )
        let home = NSHomeDirectory()
        XCTAssertEqual(
            Formatting.toolSummary(name: "Read", input: .object(["file_path": .string(home + "/a/b.txt")])),
            "~/a/b.txt"
        )
        XCTAssertEqual(
            Formatting.toolSummary(name: "Grep", input: .object(["pattern": .string("TODO")])),
            "TODO"
        )
        XCTAssertEqual(
            Formatting.toolSummary(name: "WebFetch", input: .object(["url": .string("https://x.test")])),
            "https://x.test"
        )
        XCTAssertEqual(
            Formatting.toolSummary(name: "Agent", input: .object(["description": .string("research")])),
            "research"
        )
        XCTAssertEqual(Formatting.toolSummary(name: "TodoWrite", input: .object([:])), "update todos")
        let fallback = Formatting.toolSummary(name: "Unknown", input: .object(["a": .int(1)]))
        XCTAssertTrue(fallback.contains("\"a\":1"))
    }

    func testToolSummaryTruncatesAt160() {
        let long = String(repeating: "x", count: 300)
        let summary = Formatting.toolSummary(name: "Grep", input: .object(["pattern": .string(long)]))
        XCTAssertEqual(summary.count, 160)
        XCTAssertTrue(summary.hasSuffix("…"))
    }

    func testSortedNewestFirstWithMissingDates() {
        let sessions = [
            SessionInfo(id: "none", title: "", cwd: "", model: "", updatedAt: ""),
            SessionInfo(id: "old", title: "", cwd: "", model: "", updatedAt: "2026-01-01T00:00:00Z"),
            SessionInfo(id: "new", title: "", cwd: "", model: "", updatedAt: "2026-11-08T00:00:00Z"),
        ]
        XCTAssertEqual(Formatting.sortedNewestFirst(sessions).map(\.id), ["new", "old", "none"])
    }
}

final class PaletteTests: XCTestCase {
    func testTwelvePalettesBundled() {
        XCTAssertEqual(PaletteCatalog.palettes.count, 12)
        XCTAssertEqual(Set(PaletteCatalog.palettes.map(\.key)).count, 12)
    }

    func testDefaultIsBlue() {
        XCTAssertEqual(PaletteCatalog.defaultPalette?.key, "blue")
        XCTAssertEqual(PaletteCatalog.palette(key: "blue")?.label, "Blue")
    }

    func testBlueValuesAndRGBParsing() {
        guard let blue = PaletteCatalog.palette(key: "blue") else { return XCTFail("no blue") }
        XCTAssertEqual(blue.dark.bg, "#171A21")
        XCTAssertEqual(blue.dark.wave3, "#324B8A")
        XCTAssertEqual(blue.dark.accent, "#5782D9")

        guard let rgb = RGB(hex: "#324B8A") else { return XCTFail("bad hex") }
        XCTAssertEqual(rgb.r, Double(0x32) / 255.0, accuracy: 0.0001)
        XCTAssertEqual(rgb.g, Double(0x4B) / 255.0, accuracy: 0.0001)
        XCTAssertEqual(rgb.b, Double(0x8A) / 255.0, accuracy: 0.0001)
        XCTAssertEqual(blue.dark.waves.count, 4)
        XCTAssertEqual(blue.dark.waves[3], rgb)
    }

    func testAllPaletteColorsParse() {
        for palette in PaletteCatalog.palettes {
            for mode in [palette.dark, palette.light] {
                XCTAssertNotNil(RGB(hex: mode.bg), palette.key)
                XCTAssertNotNil(RGB(hex: mode.wave0), palette.key)
                XCTAssertNotNil(RGB(hex: mode.wave1), palette.key)
                XCTAssertNotNil(RGB(hex: mode.wave2), palette.key)
                XCTAssertNotNil(RGB(hex: mode.wave3), palette.key)
                XCTAssertNotNil(RGB(hex: mode.accent), palette.key)
            }
        }
        XCTAssertNil(RGB(hex: "#12345"))
        XCTAssertNil(RGB(hex: "zzzzzz"))
    }
}

final class TokenStoreTests: XCTestCase {
    #if canImport(Security)
    func testTokenStoreRoundTrip() throws {
        throw XCTSkip("Keychain is only exercised by the app on Apple platforms.")
    }
    #else
    func testTokenStoreRoundTripInMemory() {
        let store = TokenStore(service: "local.proteus.tests")
        XCTAssertNil(store.token(for: "ws1"))
        store.setToken("tok-1", for: "ws1")
        XCTAssertEqual(store.token(for: "ws1"), "tok-1")
        store.setToken(nil, for: "ws1")
        XCTAssertNil(store.token(for: "ws1"))
        store.setToken("", for: "ws2")
        XCTAssertNil(store.token(for: "ws2"))
    }
    #endif
}
