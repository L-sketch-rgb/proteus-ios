import XCTest
@testable import ProteusKit

final class AppearanceTests: XCTestCase {

    // MARK: - Palette engine

    private func channel(_ hex: String) -> (Int, Int, Int) {
        let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let number = Int(value, radix: 16) ?? 0
        return ((number >> 16) & 0xFF, (number >> 8) & 0xFF, number & 0xFF)
    }

    private func modeValue(_ mode: PaletteMode, _ key: String) -> String {
        switch key {
        case "bg": return mode.bg
        case "wave0": return mode.wave0
        case "wave1": return mode.wave1
        case "wave2": return mode.wave2
        case "wave3": return mode.wave3
        default: return mode.accent
        }
    }

    func testCustomGoldReproducesBuiltInGoldWithinOne() throws {
        let gold = try XCTUnwrap(PaletteCatalog.palette(key: "gold"))
        let custom = PaletteEngine.customPalette(shift: 35, sat: 0.9)
        for key in PaletteEngine.seedKeys {
            for (customMode, builtInMode) in [(custom.dark, gold.dark), (custom.light, gold.light)] {
                let got = channel(modeValue(customMode, key))
                let expected = channel(modeValue(builtInMode, key))
                XCTAssertLessThanOrEqual(abs(got.0 - expected.0), 1, "\(key) red")
                XCTAssertLessThanOrEqual(abs(got.1 - expected.1), 1, "\(key) green")
                XCTAssertLessThanOrEqual(abs(got.2 - expected.2), 1, "\(key) blue")
            }
        }
    }

    func testCustomGoldMatchesPalettesPyValues() {
        // Values printed by art/palettes.py filt_hex for shift 35, sat 0.9.
        let custom = PaletteEngine.customPalette(shift: 35, sat: 0.9)
        XCTAssertEqual(custom.dark.bg, "#212018")
        XCTAssertEqual(custom.dark.wave0, "#1A1913")
        XCTAssertEqual(custom.dark.wave1, "#33301F")
        XCTAssertEqual(custom.dark.wave2, "#5E562C")
        XCTAssertEqual(custom.dark.wave3, "#8A803B")
        XCTAssertEqual(custom.dark.accent, "#D9C464")
        XCTAssertEqual(custom.light.bg, "#F8F8ED")
        XCTAssertEqual(custom.light.wave0, "#F2F3E5")
        XCTAssertEqual(custom.light.wave1, "#EBEBCE")
        XCTAssertEqual(custom.light.wave2, "#DFDDA8")
        XCTAssertEqual(custom.light.wave3, "#D3CE81")
        XCTAssertEqual(custom.light.accent, "#C9B650")
    }

    func testQAndHueDeltaMatchPalettesPy() {
        XCTAssertEqual(PaletteEngine.q(0), 0)
        XCTAssertEqual(PaletteEngine.q(35), 25)
        XCTAssertEqual(PaletteEngine.q(205), 146)
        XCTAssertEqual(PaletteEngine.q(75), 53)
        XCTAssertEqual(PaletteEngine.hueDelta8(shift: 35), 135)
        XCTAssertEqual(PaletteEngine.hueDelta8(shift: 75), 163)
        XCTAssertEqual(PaletteEngine.hueDelta8(shift: 205), 0)
    }

    // MARK: - Picked colour mapping (§1)

    func testClayAccentMapsToZeroShiftFullSaturation() throws {
        let mapping = try XCTUnwrap(PaletteEngine.mapPickedColor(hex: "#D97757"))
        XCTAssertEqual(mapping.shift, 0.0, accuracy: 1e-9)
        XCTAssertEqual(mapping.sat, 1.0, accuracy: 1e-9)
        XCTAssertEqual(mapping.color, "#D97757")
    }

    func testMappingRuleForKnownColours() throws {
        // hue(#5782D9) - hue(#D97757) = -154.615384...; saturation ratio 1.
        let blue = try XCTUnwrap(PaletteEngine.mapPickedColor(hex: "#5782D9"))
        XCTAssertEqual(blue.shift, -154.61538461538464, accuracy: 1e-9)
        XCTAssertEqual(blue.sat, 1.0, accuracy: 1e-9)

        // A grey has hue 0, so the shift is minus the clay hue; sat 0.
        let grey = try XCTUnwrap(PaletteEngine.mapPickedColor(hex: "#808080"))
        XCTAssertEqual(grey.shift, -14.769230769230774, accuracy: 1e-9)
        XCTAssertEqual(grey.sat, 0.0, accuracy: 1e-9)
    }

    func testSaturationClamp() throws {
        let red = try XCTUnwrap(PaletteEngine.mapPickedColor(hex: "#FF0000"))
        XCTAssertEqual(red.sat, 1.25, accuracy: 1e-12)
        XCTAssertEqual(red.shift, -14.769230769230774, accuracy: 1e-9)
    }

    func testShiftNormalisationIsHalfOpenAtMinus180() {
        XCTAssertEqual(PaletteEngine.normalizedShift(180), 180)
        XCTAssertEqual(PaletteEngine.normalizedShift(-180), 180)
        XCTAssertEqual(PaletteEngine.normalizedShift(190), -170)
        XCTAssertEqual(PaletteEngine.normalizedShift(-190), 170)
        XCTAssertEqual(PaletteEngine.normalizedShift(360), 0)
        XCTAssertEqual(PaletteEngine.normalizedShift(-360), 0)
    }

    // MARK: - Image filter (fixture generated with Pillow 12.3.0)

    // 16x8 RGBA fixture: primaries, greys, the clay seeds and a deterministic
    // pattern. Expected bytes are from art/palettes.py's filt_img.
    private let fixtureInput = "AAAAAP////+AgID//wAA/wD/AP8AAP//2XdX/yEaF//48ez/ikoy/wECA/9klsiAyJZkQArIHgHICh7IHgrI/ws1BykwQmJGVU+9Y3pcGICfaXOdxHbOuumDKdcOkIT0M53fEViqOi59t5VLosTwaMfRS4Xs3qaiEesBvzb4XNwWag5SO3dpb2CExIyFkR+pqp56xs+r1eP0uDAAGcWLHT7S5jpj30FXiOycdK3595HSBlKu9xOtyxwgCOhBLWMFIZ8Ve0ascJhrucu1kMYm0rXTge/a4NwM/+03KST6kkZJB+1jbhRIgJMho524Lv663TtZ1wJItPQnVQ8RTGJqLizUHKRR4XfBdu7S3pv7LfvACIgY5RXjNQoiPlIvL5lvVDz0jHlJT6meVqrGw2MF4+hwYAANfbsdMooWOleXcVc3CSPNXBZ+6oEj2QemMDQkyz2PQfBK6l4VV0V7OmSgmF9x+7WEflbSqYux786YDAzzpWcpGLLCRj2/HWNizHiAQj4q9mdLhROMWOAwsWU7TdZylmr7f/GHIIxMpEWZp8FqpgLej7Nd+7TAuBjZzRM1/tpuUiPnyW9I9CSMbQF/qU1zMR9ygIw8l43nWbyaQnbhp52TBrT4sCvBU81Qzq7qddsJB5roZCS/9b9B5AIaXgkPdXsuHNCYUykrtXg2htI="

    private let goldFilteredFixture = "AAAAAP////+AgID/Gdb///8Z1v/c/xn/ZKnZ/xgdIf/t8vj/O2iK/wMCAf/Ip2+Ab4zIQMgdmgEdwsjInsgd/zUMMiliWDVGqb1aYyIueoBvn52dgM6Bujx96deQIRv035VFEZ9Fqi63g5lL8NyqaHVZ0YWtr+yi6xnVv/hKudxqF2NSd0FFb8SwaoxFK5Gpf4Oqxq/Vr+NEXfQAxSpEHeZ2TzrXUd9X7JLLdPm+tpEb0qmuKveKyxIKIOhKYzIFnyOVe6xQd5jLkXW1fTbG0rGJ0+/g3N4MWEv/Kfo6eUaT7R9jHW5LgC6jMZ1n/kS6TN3Y17SMFPRKFlURalpPLtQvxqThX6nB7oOK3rhC+/sawGQYKuVFNT4vD1KLmTpvx/ROjE54ealfql/GGFHD427H6AC7bB8dgSKKOpdedlcONyXNMn4h6m/ZNgc8m6YkTMuUQVvwd15XHCN7oIdEmPb7b7VcW4TSkbGP7yA0zgx2qPMpwk0pRrouv2PMbamALS1C9mSFUROf4GYwR3mxTXzWwmqN+6SHjCtUpKdoT8FiE6bek2az+8C1uxg4J9k1fYn+Uuc3N2/yOfSMDn8OqWM4cx+Mg3U80+eWWU9cvHakzuGT+HsfsME6hs3OXWjqmx7bB8ty6CT1xe1BGd3kXm11FHuo0C6YLVBTtUCGPtI="

    private let mossFilteredFixture = "AAAAAP////+AgID/QF////9AX/9k/0D/f3jZ/xoZIf/x7/j/TkiK/wMDAf+yyH2Aln3IQMg5QwE5ZcjIR8g5/zUSGylSYjxGdr1rY1cxeoB3hp+djc65uoFZ6deQcy/0yN9eEapWfC63lYxL2/C2aMZt0YXZuOyi6zxlv/hnZ9xqJTdSd2NKb6PEeYyKPJGpmoaqxrXVyuOtYvQAxYFFHebcaDrfaZhX7KGhdPnswJE6kNKuTeH3yyAOIOg7Y0EFnzdSe6xwYJjLyoO1xk600tOWx+/g3dwM1mn/KfqKWUZB7VFjK19ugEKjhJ1j/qy6ZJHd1320L/RVIDwRaWpULtRKbqThfXXB7seU3vtgzvs2scAYSuXGNTE+F1JZmUpvdPRqjFVhealrqpXGZDXD44KJ6ACnuzgdijNYOpdxZ1cULzfNMH5V6lHZegdNYqYkYLPLQXTw3V5XPyZ7gqBTmKr7h7V5YoTSlbGm74s9zgylivMpwrVDRr9Gc2PMfX2APDBC9lqFZhN64I0waVixTYu11mqe+++HjEw7pKejXsGmLI7es3Kj+8C5uBi0Rdk1z5L+UuexVG/0WI+MIX9fqXNBYB+HjHk8quekWZJhvHaur+GT6fhDsMFZUc3Oo3Dq2z6pB+iFvyT1zdNBO2/kXjl1JHtW0EmYMzxTtUqGcNI="

    func testImageFilterMatchesPillowForGold() throws {
        let input = try XCTUnwrap(Data(base64Encoded: fixtureInput))
        let expected = try XCTUnwrap(Data(base64Encoded: goldFilteredFixture))
        let filtered = PaletteEngine.filterRGBA(input, shift: 35, sat: 0.9)
        XCTAssertEqual([UInt8](filtered), [UInt8](expected))
    }

    func testImageFilterMatchesPillowForMoss() throws {
        let input = try XCTUnwrap(Data(base64Encoded: fixtureInput))
        let expected = try XCTUnwrap(Data(base64Encoded: mossFilteredFixture))
        let filtered = PaletteEngine.filterRGBA(input, shift: 75, sat: 0.75)
        XCTAssertEqual([UInt8](filtered), [UInt8](expected))
    }

    func testImageFilterIdentityShortCircuits() throws {
        let input = try XCTUnwrap(Data(base64Encoded: fixtureInput))
        XCTAssertEqual(PaletteEngine.filterRGBA(input, shift: 205, sat: 1.0), input)
        XCTAssertEqual(PaletteEngine.filterRGBA([UInt8](input), dhue8: 0, sat: 1.0), [UInt8](input))
    }

    // MARK: - Slots, selection fallback and frames

    private func slot(_ shift: Double, _ sat: Double, color: String = "#D97757") -> AppearanceSlot {
        AppearanceSlot(color: color, shift: shift, sat: sat, savedAt: "2026-11-09T00:00:00Z")
    }

    func testSelectionFallsBackToBlueWhenCustomSlotEmpties() {
        let store = AppearanceStore()
        let slots: [AppearanceSlot?] = [nil, nil, slot(35, 0.9), nil, nil]
        store.apply(slots: slots)
        XCTAssertEqual(store.resolvedSelection(for: "custom:2"), "custom:2")
        XCTAssertEqual(store.resolve("custom:2").palette.dark.accent, "#D9C464")

        var emptied = slots
        emptied[2] = nil
        store.apply(slots: emptied)
        XCTAssertEqual(store.resolvedSelection(for: "custom:2"), "blue")
        XCTAssertEqual(store.resolve("custom:2").palette.key, "blue")
        XCTAssertFalse(store.resolve("custom:2").isCustom)
    }

    func testSelectionFallsBackForUnknownBuiltIn() {
        let store = AppearanceStore()
        XCTAssertEqual(store.resolvedSelection(for: "nope"), "blue")
        XCTAssertEqual(store.resolvedSelection(for: "custom:9"), "blue")
        XCTAssertEqual(store.resolve("blue").palette.key, "blue")
    }

    func testSlotsAreAlwaysFive() {
        let store = AppearanceStore()
        store.apply(slots: [slot(0, 1)])
        XCTAssertEqual(store.slots.count, 5)
        XCTAssertNotNil(store.slots[0])
        XCTAssertNil(store.slots[4])

        store.apply(slots: Array(repeating: slot(0, 1), count: 7))
        XCTAssertEqual(store.slots.count, 5)
    }

    func testBroadcastAppliesSlotsAndNotifies() throws {
        let json = ##"{"t":"appearance","slots":[null,{"color":"#D97757","shift":0,"sat":1,"savedAt":"2026-11-09T00:00:00Z"},null,null,null]}"##
        guard case .appearance(let frame) = try ServerMessage.decode(Data(json.utf8)) else {
            return XCTFail("not appearance")
        }
        let store = AppearanceStore()
        var notified = 0
        store.onSlotsChanged = { notified += 1 }
        store.apply(frame: frame)
        XCTAssertEqual(notified, 1)
        XCTAssertEqual(store.slots[1]?.color, "#D97757")
        XCTAssertNil(store.slots[0])
    }

    func testWelcomeCarriesAppearanceSlots() throws {
        let json = ##"{"t":"welcome","accounts":[],"active":"","sessions":[],"models":[],"defaultModel":"","appearance":{"slots":[{"color":"#123456","shift":-10,"sat":0.5,"savedAt":"2026-11-09T00:00:00Z"},null,null,null,null]}}"##
        guard case .welcome(let welcome) = try ServerMessage.decode(Data(json.utf8)) else {
            return XCTFail("not welcome")
        }
        XCTAssertEqual(welcome.appearance?.slots.count, 5)
        let first: AppearanceSlot? = welcome.appearance?.slots[0] ?? nil
        XCTAssertEqual(first?.shift, -10)
        XCTAssertNil(welcome.appearance?.slots[1])
    }

    func testWelcomeWithoutAppearanceStillDecodes() throws {
        let json = #"{"t":"welcome","accounts":[],"active":"","sessions":[],"models":[],"defaultModel":""}"#
        guard case .welcome(let welcome) = try ServerMessage.decode(Data(json.utf8)) else {
            return XCTFail("not welcome")
        }
        XCTAssertNil(welcome.appearance)
    }

    func testSetSlotFrameEncoding() throws {
        let filled = ClientFrame.appearanceSetSlot(index: 3, slot: slot(35, 0.9), rid: "r1")
        let object = try JSONDecoder.proteus.decode(JSONValue.self, from: filled.encoded())
        XCTAssertEqual(object["t"]?.stringValue, "appearance.setSlot")
        XCTAssertEqual(object["rid"]?.stringValue, "r1")
        XCTAssertEqual(object["index"]?.intValue, 3)
        XCTAssertEqual(object["slot"]?["color"]?.stringValue, "#D97757")
        XCTAssertEqual(object["slot"]?["shift"]?.doubleValue, 35)
        XCTAssertEqual(object["slot"]?["sat"]?.doubleValue, 0.9)
        XCTAssertEqual(object["slot"]?["savedAt"]?.stringValue, "2026-11-09T00:00:00Z")

        let cleared = ClientFrame.appearanceSetSlot(index: 3, slot: nil)
        let clearedObject = try JSONDecoder.proteus.decode(JSONValue.self, from: cleared.encoded())
        XCTAssertTrue(clearedObject["slot"]?.isNull ?? false)
    }

    func testSlotFromPickedColorUsesMapping() throws {
        let picked = try XCTUnwrap(AppearanceSlot.fromPickedColor("#D97757", savedAt: "t"))
        XCTAssertEqual(picked.color, "#D97757")
        XCTAssertEqual(picked.shift, 0, accuracy: 1e-9)
        XCTAssertEqual(picked.sat, 1, accuracy: 1e-9)
        XCTAssertEqual(picked.savedAt, "t")
    }
}
