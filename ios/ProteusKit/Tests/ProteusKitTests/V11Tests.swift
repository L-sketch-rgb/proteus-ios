import XCTest
@testable import ProteusKit

/// v10 §13/§15.1/§15.4/§16 and v11 §1: pins, hub features, presets and the
/// stopped notice.
final class V11FrameTests: XCTestCase {
    private func object(_ frame: ClientFrame) throws -> JSONValue {
        try JSONDecoder.proteus.decode(JSONValue.self, from: frame.encoded())
    }

    func testPinFramesEncode() throws {
        let add = try object(.pinAdd(
            id: "s1",
            seq: 7,
            kind: "assistant",
            excerpt: "The quick reply",
            ts: "2026-11-09T08:00:00Z",
            rid: "r1"
        ))
        XCTAssertEqual(add["t"]?.stringValue, "pin.add")
        XCTAssertEqual(add["id"]?.stringValue, "s1")
        XCTAssertEqual(add["seq"]?.intValue, 7)
        XCTAssertEqual(add["kind"]?.stringValue, "assistant")
        XCTAssertEqual(add["excerpt"]?.stringValue, "The quick reply")
        XCTAssertEqual(add["ts"]?.stringValue, "2026-11-09T08:00:00Z")
        XCTAssertEqual(add["rid"]?.stringValue, "r1")

        let noTime = try object(.pinAdd(id: "s1", seq: 0, kind: "user", excerpt: "Hi", ts: ""))
        XCTAssertNil(noTime["ts"])

        let remove = try object(.pinRemove(id: "s1", pinId: "p1"))
        XCTAssertEqual(remove["t"]?.stringValue, "pin.remove")
        XCTAssertEqual(remove["id"]?.stringValue, "s1")
        XCTAssertEqual(remove["pinId"]?.stringValue, "p1")
    }

    func testPresetFramesEncode() throws {
        let save = try object(.presetSave(
            name: "Focus",
            agentPolicy: "Delegate searches",
            subagents: [SubagentDef(name: "coder", when: "types code", model: "fast", tools: "all")]
        ))
        XCTAssertEqual(save["t"]?.stringValue, "preset.save")
        XCTAssertEqual(save["name"]?.stringValue, "Focus")
        XCTAssertEqual(save["agentPolicy"]?.stringValue, "Delegate searches")
        XCTAssertEqual(save["subagents"]?.arrayValue?.first?["name"]?.stringValue, "coder")

        let emptyPolicy = try object(.presetSave(name: "Bare", agentPolicy: nil, subagents: []))
        XCTAssertEqual(emptyPolicy["agentPolicy"]?.stringValue, "")

        let delete = try object(.presetDelete(presetId: "pr1"))
        XCTAssertEqual(delete["t"]?.stringValue, "preset.delete")
        XCTAssertEqual(delete["presetId"]?.stringValue, "pr1")
    }

    func testOkFrameCarriesPinAndPresetIds() throws {
        let ok = """
        {"t":"ok","rid":"r1","pinId":"p1","presetId":"pr1"}
        """
        guard case .ok(let frame) = try ServerMessage.decode(Data(ok.utf8)) else {
            return XCTFail("expected ok")
        }
        XCTAssertEqual(frame.rid, "r1")
        XCTAssertEqual(frame.pinId, "p1")
        XCTAssertEqual(frame.presetId, "pr1")
    }

    func testWelcomeDecodesFeaturesPinsAndPresets() throws {
        let json = """
        {"t":"welcome","features":["fs","pins","resend","notices","presets","questions"],
         "pins":{"s1":[{"pinId":"p1","seq":4,"kind":"assistant","excerpt":"Hi",
                        "ts":"2026-11-09T08:00:00Z","pinnedAt":"2026-11-09T09:00:00Z"}]},
         "presets":[{"presetId":"pr1","name":"Focus","agentPolicy":"Delegate",
                     "subagents":[{"name":"coder","when":"write","model":"fast","tools":"all"}]}]}
        """
        guard case .welcome(let welcome) = try ServerMessage.decode(Data(json.utf8)) else {
            return XCTFail("expected welcome")
        }
        // v10 §15.1 addition: the hub advertises question-card support.
        XCTAssertEqual(welcome.features, ["fs", "pins", "resend", "notices", "presets", "questions"])
        XCTAssertTrue(welcome.features?.contains("questions") == true)
        XCTAssertEqual(welcome.pins["s1"]?.count, 1)
        XCTAssertEqual(welcome.pins["s1"]?.first?.pinId, "p1")
        XCTAssertEqual(welcome.pins["s1"]?.first?.seq, 4)
        XCTAssertEqual(welcome.pins["s1"]?.first?.pinnedAt, "2026-11-09T09:00:00Z")
        XCTAssertEqual(welcome.presets.count, 1)
        XCTAssertEqual(welcome.presets.first?.presetId, "pr1")
        XCTAssertEqual(welcome.presets.first?.agentPolicy, "Delegate")
        XCTAssertEqual(welcome.presets.first?.subagents.first?.tools, "all")
    }

    func testWelcomeWithoutFeaturesIsAnOlderHub() throws {
        let json = """
        {"t":"welcome","hubVersion":"0.6.0"}
        """
        guard case .welcome(let welcome) = try ServerMessage.decode(Data(json.utf8)) else {
            return XCTFail("expected welcome")
        }
        XCTAssertNil(welcome.features)
        XCTAssertTrue(welcome.pins.isEmpty)
        XCTAssertTrue(welcome.presets.isEmpty)
    }

    func testPinsAndPresetsBroadcastsDecode() throws {
        let pins = """
        {"t":"pins","id":"s1","pins":[
          {"pinId":"p1","seq":2,"kind":"tool","excerpt":"swift test","ts":"","pinnedAt":"2026-11-09T09:00:00Z"}
        ]}
        """
        guard case .pins(let frame) = try ServerMessage.decode(Data(pins.utf8)) else {
            return XCTFail("expected pins")
        }
        XCTAssertEqual(frame.id, "s1")
        XCTAssertEqual(frame.pins.first?.kind, "tool")
        XCTAssertEqual(frame.pins.first?.ts, "")

        let presets = """
        {"t":"presets","presets":[{"presetId":"pr1","name":"Focus","subagents":[]}]}
        """
        guard case .presets(let list) = try ServerMessage.decode(Data(presets.utf8)) else {
            return XCTFail("expected presets")
        }
        XCTAssertEqual(list.presets.map(\.name), ["Focus"])
        XCTAssertNil(list.presets.first?.agentPolicy)
    }

    func testTimestampFromDateUsesLocale() {
        let now = Formatting.parseISO("2026-11-09T12:00:00Z")!
        let utc = TimeZone(identifier: "UTC")!
        let date = Formatting.parseISO("2026-11-09T08:05:00Z")!
        XCTAssertEqual(
            Formatting.timestamp(date, now: now, timeZone: utc, locale: Locale(identifier: "en_GB")),
            "08:05"
        )
    }
}

final class V11ChatStoreTests: XCTestCase {
    private func event(
        _ seq: Int,
        _ kind: String,
        _ data: [String: JSONValue],
        ts: String = "2026-11-09T10:00:00Z"
    ) -> HubEvent {
        HubEvent(id: "s1", seq: seq, ts: ts, kind: kind, data: .object(data))
    }

    private func toolUse(_ id: String, _ name: String) -> JSONValue {
        .object([
            "type": .string("tool_use"),
            "id": .string(id),
            "name": .string(name),
            "input": .object(["command": .string("npm test")]),
        ])
    }

    private func assistant(_ seq: Int, _ blocks: [JSONValue]) -> HubEvent {
        event(seq, "assistant", ["blocks": .array(blocks)])
    }

    func testStoppedNoticeIsMutedAndMarksUnfinishedTools() {
        let store = ChatStore()
        store.apply(assistant(1, [toolUse("tool-1", "Bash")]))
        store.apply(event(2, "notice", ["kind": .string("stopped")]))

        XCTAssertEqual(store.rows.map(\.kind), [.tool, .notice])
        let notice = store.rows[1]
        XCTAssertEqual(notice.text, "Stopped")
        XCTAssertEqual(notice.noticeKind, "stopped")
        XCTAssertEqual(notice.timestamp, Formatting.timestamp("2026-11-09T10:00:00Z"))
        XCTAssertTrue(store.toolRow(withId: "tool-1")?.toolStopped == true)
        XCTAssertFalse(store.toolRow(withId: "tool-1")?.toolError == true)
    }

    func testStoppedGroupIsGreyNotFailed() {
        let store = ChatStore()
        store.apply(assistant(1, [toolUse("tool-1", "Bash"), toolUse("tool-2", "Read")]))
        store.apply(event(2, "notice", ["kind": .string("stopped")]))

        XCTAssertEqual(store.rows.first?.kind, .toolgroup)
        XCTAssertTrue(store.rows.first?.groupStopped == true)
        XCTAssertFalse(store.rows.first?.groupRunning == true)
        XCTAssertEqual(store.rows.first?.groupFailed, 0)
    }

    func testStoppedNoticeDoesNotTouchFinishedTools() {
        let store = ChatStore()
        store.apply(assistant(1, [toolUse("tool-1", "Bash")]))
        store.apply(event(2, "tool_result", [
            "toolUseId": .string("tool-1"),
            "isError": .bool(true),
            "text": .string("exit 1"),
        ]))
        store.apply(event(3, "notice", ["kind": .string("stopped")]))

        let tool = store.toolRow(withId: "tool-1")
        XCTAssertFalse(tool?.toolStopped == true)
        XCTAssertTrue(tool?.toolError == true)
    }

    func testPinMatchesRowBySeqAndKind() throws {
        let store = ChatStore()
        store.apply(event(1, "user", ["text": .string("Please check the form")]))
        store.apply(assistant(2, [
            .object(["type": .string("text"), "text": .string("I will trace it")]),
            toolUse("tool-1", "Bash"),
        ]))

        let assistantPin = Pin(
            pinId: "p1", seq: 2, kind: "assistant", excerpt: "I will trace it"
        )
        let row = try XCTUnwrap(store.row(matching: assistantPin))
        XCTAssertEqual(row.kind, .assistant)
        XCTAssertEqual(row.text, "I will trace it")
        XCTAssertEqual(row.eventSeq, 2)

        let toolPin = Pin(pinId: "p2", seq: 2, kind: "tool", excerpt: "npm test")
        let toolRow = try XCTUnwrap(store.row(matching: toolPin))
        XCTAssertEqual(toolRow.kind, .tool)
        XCTAssertEqual(toolRow.toolId, "tool-1")
    }

    func testPinWithoutSeqMatchesKindAndExcerpt() throws {
        let store = ChatStore()
        store.apply(event(1, "user", ["text": .string("Please check the form")]))
        // History items carry seq 0; the pin is matched by kind plus excerpt.
        let pin = Pin(pinId: "p1", seq: 0, kind: "user", excerpt: "Please check")
        let row = try XCTUnwrap(store.row(matching: pin))
        XCTAssertEqual(row.kind, .user)
        XCTAssertEqual(row.text, "Please check the form")

        let gone = Pin(pinId: "p2", seq: 0, kind: "user", excerpt: "not here")
        XCTAssertNil(store.row(matching: gone))
    }

    func testGroupPinUsesItsFirstToolsSeq() throws {
        let store = ChatStore()
        store.apply(assistant(5, [toolUse("tool-1", "Bash"), toolUse("tool-2", "Read")]))
        let pin = Pin(pinId: "p1", seq: 5, kind: "group", excerpt: "Bash ×1 · Read ×1")
        let row = try XCTUnwrap(store.row(matching: pin))
        XCTAssertEqual(row.kind, .toolgroup)
        XCTAssertEqual(row.eventSeq, 5)
        XCTAssertEqual(row.pinKind, "group")
    }

    func testPinExcerptCutAt160StillMatchesHistoryRow() {
        let store = ChatStore()
        let long = String(repeating: "a", count: 200)
        // A live pin stores a 160-character excerpt ending in an ellipsis; the
        // history row (seq 0) holds the full text.
        let pin = Pin(
            pinId: "p1",
            seq: 0,
            kind: "user",
            excerpt: Formatting.truncate(long, 160)
        )
        store.apply(event(1, "user", ["text": .string(long)]))
        XCTAssertNotNil(store.row(matching: pin))
    }
}
