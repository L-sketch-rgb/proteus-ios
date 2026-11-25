import XCTest
@testable import ProteusKit

/// v10 §2, §3, §7, §8/§8.1 and §11: tool groups, timestamps, fs frames,
/// notices and editing a sent prompt.
final class V10FrameTests: XCTestCase {
    private func object(_ frame: ClientFrame) throws -> JSONValue {
        try JSONDecoder.proteus.decode(JSONValue.self, from: frame.encoded())
    }

    func testResendFrameEncoding() throws {
        let plain = try object(.sessionResend(id: "s1", text: "fix it", rid: "r1"))
        XCTAssertEqual(plain["t"]?.stringValue, "session.resend")
        XCTAssertEqual(plain["id"]?.stringValue, "s1")
        XCTAssertEqual(plain["text"]?.stringValue, "fix it")
        XCTAssertEqual(plain["rid"]?.stringValue, "r1")
        XCTAssertNil(plain["images"])

        let images = [ImageIn(mediaType: "image/png", data: "AAA")]
        let withImages = try object(.sessionResend(id: "s1", text: "look", images: images))
        XCTAssertEqual(withImages["t"]?.stringValue, "session.resend")
        XCTAssertEqual(withImages["images"]?.arrayValue?.first?["mediaType"]?.stringValue, "image/png")
    }

    func testFsListAndReadFrames() throws {
        let list = try object(.fsList(id: "s1", path: "/work/docs", rid: "r1"))
        XCTAssertEqual(list["t"]?.stringValue, "fs.list")
        XCTAssertEqual(list["id"]?.stringValue, "s1")
        XCTAssertEqual(list["path"]?.stringValue, "/work/docs")
        XCTAssertEqual(list["rid"]?.stringValue, "r1")

        let read = try object(.fsRead(id: "s1", path: "/work/a.txt"))
        XCTAssertEqual(read["t"]?.stringValue, "fs.read")
        XCTAssertNil(read["maxBytes"])

        let capped = try object(.fsRead(id: "s1", path: "/work/a.txt", maxBytes: 4096))
        XCTAssertEqual(capped["maxBytes"]?.intValue, 4096)
    }

    func testFsListingDecoding() throws {
        let json = """
        {"t":"fs.listing","rid":"r1","path":"/work","skipped":false,"entries":[
          {"name":"docs","dir":true,"size":0,"mtime":"2026-11-09T08:00:00Z"},
          {"name":".env","dir":false,"size":12,"mtime":"2026-11-09T09:00:00Z","hidden":true},
          {"name":"README.md"}
        ]}
        """
        guard case .fsListing(let frame) = try ServerMessage.decode(Data(json.utf8)) else {
            return XCTFail("expected fs.listing")
        }
        XCTAssertEqual(frame.path, "/work")
        XCTAssertEqual(frame.rid, "r1")
        XCTAssertEqual(frame.entries.map(\.name), ["docs", ".env", "README.md"])
        XCTAssertTrue(frame.entries[0].dir)
        XCTAssertTrue(frame.entries[1].hidden)
        // Lenient defaults for fields the hub may omit.
        XCTAssertFalse(frame.entries[2].dir)
        XCTAssertEqual(frame.entries[2].size, 0)
        XCTAssertFalse(frame.entries[2].hidden)
    }

    func testFsFileDecodingTextAndImage() throws {
        let text = """
        {"t":"fs.file","path":"/work/a.txt","size":5,"mtime":"2026-11-09T08:00:00Z",
         "binary":false,"truncated":true,"text":"hello"}
        """
        guard case .fsFile(let frame) = try ServerMessage.decode(Data(text.utf8)) else {
            return XCTFail("expected fs.file")
        }
        XCTAssertEqual(frame.text, "hello")
        XCTAssertTrue(frame.truncated)
        XCTAssertFalse(frame.binary)

        let image = """
        {"t":"fs.file","path":"/work/a.png","size":3,"binary":false,"image":"AAAA"}
        """
        guard case .fsFile(let picture) = try ServerMessage.decode(Data(image.utf8)) else {
            return XCTFail("expected fs.file")
        }
        XCTAssertEqual(picture.image, "AAAA")
        XCTAssertNil(picture.text)
    }

    func testTimestampFormatting() {
        let now = Formatting.parseISO("2026-11-09T12:00:00Z")!
        let utc = TimeZone(identifier: "UTC")!
        // v11 §1: the locale decides 12/24 h and the day/month names.
        let locale = Locale(identifier: "en_GB")
        XCTAssertEqual(
            Formatting.timestamp("2026-11-09T08:05:00Z", now: now, timeZone: utc, locale: locale),
            "08:05"
        )
        let otherDay = Formatting.timestamp(
            "2026-11-07T08:05:00Z", now: now, timeZone: utc, locale: locale
        )
        // Punctuation varies by CLDR version; the day/month names and the
        // 24-hour time must still be there.
        XCTAssertTrue(otherDay.contains("Sat"))
        XCTAssertTrue(otherDay.contains("Nov"))
        XCTAssertTrue(otherDay.hasSuffix("08:05"))
        XCTAssertEqual(Formatting.timestamp("", now: now, timeZone: utc, locale: locale), "")
        XCTAssertEqual(Formatting.timestamp("not a date", now: now, timeZone: utc, locale: locale), "")
    }

    func testTimeSpanFormatting() {
        let now = Formatting.parseISO("2026-11-09T12:00:00Z")!
        let utc = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_GB")
        XCTAssertEqual(
            Formatting.timeRange(
                "2026-11-09T09:12:00Z", "2026-11-09T09:14:00Z", now: now, timeZone: utc, locale: locale
            ),
            "09:12–09:14"
        )
        XCTAssertEqual(
            Formatting.timeRange(
                "2026-11-09T09:12:00Z", "2026-11-09T09:12:00Z", now: now, timeZone: utc, locale: locale
            ),
            "09:12"
        )
        let span = Formatting.timeRange(
            "2026-11-08T22:00:00Z", "2026-11-09T01:00:00Z", now: now, timeZone: utc, locale: locale
        )
        XCTAssertTrue(span.contains("Sun"))
        XCTAssertTrue(span.contains("Mon"))
        XCTAssertTrue(span.contains("22:00"))
        XCTAssertTrue(span.contains("01:00"))
        XCTAssertTrue(span.contains("–"))
        XCTAssertEqual(
            Formatting.timeRange("", "2026-11-09T01:00:00Z", now: now, timeZone: utc, locale: locale),
            "01:00"
        )
        XCTAssertEqual(
            Formatting.timeRange("2026-11-09T01:00:00Z", "", now: now, timeZone: utc, locale: locale),
            "01:00"
        )
        XCTAssertEqual(Formatting.timeRange("", "", now: now, timeZone: utc, locale: locale), "")
    }
}

final class V10ChatStoreTests: XCTestCase {
    private func event(
        _ seq: Int,
        _ kind: String,
        _ data: [String: JSONValue],
        ts: String = "2026-11-09T10:00:00Z"
    ) -> HubEvent {
        HubEvent(id: "s1", seq: seq, ts: ts, kind: kind, data: .object(data))
    }

    private func toolUse(_ id: String, _ name: String, command: String) -> JSONValue {
        .object([
            "type": .string("tool_use"),
            "id": .string(id),
            "name": .string(name),
            "input": .object(["command": .string(command)]),
        ])
    }

    private func assistantEvent(_ seq: Int, _ blocks: [JSONValue], ts: String = "2026-11-09T10:00:00Z") -> HubEvent {
        event(seq, "assistant", ["blocks": .array(blocks)], ts: ts)
    }

    func testTwoToolCardsCollapseIntoOneGroup() {
        let store = ChatStore()
        store.apply(assistantEvent(1, [
            toolUse("tool-1", "Bash", command: "swift test"),
            toolUse("tool-2", "Bash", command: "swift build"),
        ]))

        XCTAssertEqual(store.rows.map(\.kind), [.toolgroup, .tool, .tool])
        let header = store.rows[0]
        XCTAssertEqual(header.groupId, "tool-1")
        XCTAssertEqual(header.groupCount, 2)
        XCTAssertEqual(header.groupLabel, "commands")
        XCTAssertEqual(header.groupSummary, "Bash ×2")
        XCTAssertFalse(header.groupExpanded)
        XCTAssertTrue(header.groupRunning)
        XCTAssertEqual(header.groupFailed, 0)
        XCTAssertEqual(header.groupLatest, "swift build")
        XCTAssertEqual(header.tsRaw, "2026-11-09T10:00:00Z")
        XCTAssertFalse(header.groupSpan.isEmpty)

        // Collapsed: only the flat header is drawn; the cards are kept in rows.
        XCTAssertEqual(store.visibleRows.map(\.kind), [.toolgroup])
        XCTAssertEqual(store.entryCount, 2)

        store.toggleGroup(header.groupId)
        XCTAssertTrue(store.rows[0].groupExpanded)
        XCTAssertTrue(store.rows[1].groupExpanded)
        XCTAssertEqual(store.visibleRows.map(\.kind), [.toolgroup, .tool, .tool])
        XCTAssertFalse(store.rows[0].groupSpan.isEmpty)
    }

    func testToolGroupMetadataUsesNamesCountsAndFailures() {
        let store = ChatStore()
        store.apply(assistantEvent(1, [
            toolUse("tool-1", "Bash", command: "ls"),
            toolUse("tool-2", "Read", command: "/tmp/a"),
            toolUse("tool-3", "Bash", command: "false"),
        ]))
        let header = store.rows[0]
        XCTAssertEqual(header.groupLabel, "tool calls")
        XCTAssertEqual(header.groupSummary, "Bash ×2 · Read ×1")
        XCTAssertEqual(header.groupCount, 3)

        store.apply(event(2, "tool_result", [
            "toolUseId": .string("tool-3"),
            "isError": .bool(true),
            "text": .string("exit 1"),
        ]))
        store.apply(event(3, "tool_result", [
            "toolUseId": .string("tool-2"),
            "isError": .bool(false),
            "text": .string("file"),
        ]))
        store.apply(event(4, "tool_result", [
            "toolUseId": .string("tool-1"),
            "isError": .bool(false),
            "text": .string("a.txt"),
        ]))
        let updated = store.rows[0]
        XCTAssertFalse(updated.groupRunning)
        XCTAssertEqual(updated.groupFailed, 1)
    }

    func testSingleToolAndTaskCardsAreNotGrouped() {
        let single = ChatStore()
        single.apply(assistantEvent(1, [toolUse("tool-1", "Bash", command: "ls")]))
        XCTAssertEqual(single.rows.map(\.kind), [.tool])

        let tasks = ChatStore()
        tasks.apply(assistantEvent(1, [
            toolUse("tool-1", "Task", command: "research"),
            toolUse("tool-2", "Agent", command: "write"),
        ]))
        XCTAssertEqual(tasks.rows.map(\.kind), [.tool, .tool])
    }

    func testNestedToolCallsAreNotGrouped() {
        let store = ChatStore()
        let block: JSONValue = .object([
            "type": .string("tool_use"),
            "id": .string("tool-1"),
            "name": .string("Bash"),
            "input": .object(["command": .string("ls")]),
        ])
        store.apply(event(1, "assistant", [
            "parent": .string("tool-9"),
            "blocks": .array([block, block]),
        ]))
        XCTAssertEqual(store.rows.map(\.kind), [.tool, .tool])
        XCTAssertTrue(store.rows.allSatisfy(\.nested))
    }

    func testAssistantTimestampAppearsOncePerTurn() {
        let store = ChatStore()
        store.apply(event(1, "text_delta", ["text": .string("one")], ts: "2026-11-09T08:00:00Z"))
        store.apply(event(2, "text_delta", ["text": .string(" two")], ts: "2026-11-09T08:05:00Z"))
        XCTAssertEqual(store.rows.count, 1)
        XCTAssertEqual(store.rows[0].timestamp, Formatting.timestamp("2026-11-09T08:00:00Z"))
        XCTAssertEqual(store.rows[0].tsRaw, "2026-11-09T08:00:00Z")

        store.apply(event(3, "user", ["text": .string("again")], ts: "2026-11-09T09:00:00Z"))
        store.apply(event(4, "text_delta", ["text": .string("second")], ts: "2026-11-09T09:05:00Z"))
        let last = store.rows.last
        XCTAssertEqual(last?.kind, .assistant)
        XCTAssertEqual(last?.timestamp, Formatting.timestamp("2026-11-09T09:05:00Z"))
    }

    func testAssistantTimestampNeverInvented() {
        let store = ChatStore()
        store.apply(event(1, "text_delta", ["text": .string("no time")], ts: ""))
        XCTAssertEqual(store.rows[0].timestamp, "")
        XCTAssertEqual(store.rows[0].tsRaw, "")
    }

    func testTaskNotice() {
        let store = ChatStore()
        store.apply(event(1, "notice", [
            "kind": .string("task"),
            "summary": .string("Background command “swift test” completed"),
            "status": .string("completed"),
        ]))
        XCTAssertEqual(store.rows.count, 1)
        XCTAssertEqual(store.rows[0].kind, .notice)
        XCTAssertEqual(store.rows[0].text, "⚙ Background command “swift test” completed")
        XCTAssertEqual(store.rows[0].timestamp, Formatting.timestamp("2026-11-09T10:00:00Z"))
    }

    func testTaskNoticeFallsBackToStatus() {
        let store = ChatStore()
        store.apply(event(1, "notice", ["kind": .string("task"), "status": .string("failed")]))
        XCTAssertEqual(store.rows[0].text, "⚙ Background task failed")

        let bare = ChatStore()
        bare.apply(event(1, "notice", ["kind": .string("task")]))
        XCTAssertEqual(bare.rows[0].text, "⚙ Background task")
    }

    func testReminderNotice() {
        let store = ChatStore()
        store.apply(event(1, "notice", [
            "kind": .string("reminder"),
            "summary": .string("The build is still running"),
        ]))
        XCTAssertEqual(store.rows[0].text, "The build is still running")
        XCTAssertNil(store.rows[0].noticeKind)
    }

    func testAgentNoticeAndExpandableReport() {
        let store = ChatStore()
        store.apply(event(1, "notice", [
            "kind": .string("agent"),
            "from": .string("coder"),
            "summary": .string("Fixed the parser"),
            "report": .string("Fixed the parser.\nAll tests pass."),
        ]))
        let row = store.rows[0]
        XCTAssertEqual(row.text, "↩ Sub-agent report: Fixed the parser")
        XCTAssertEqual(row.noticeKind, "agent")
        XCTAssertEqual(row.noticeFrom, "coder")
        XCTAssertEqual(row.noticeReport, "Fixed the parser.\nAll tests pass.")
        XCTAssertEqual(row.timestamp, Formatting.timestamp("2026-11-09T10:00:00Z"))
    }

    func testAgentNoticeWithoutReportIsNotExpandable() {
        let store = ChatStore()
        store.apply(event(1, "notice", [
            "kind": .string("agent"),
            "from": .string("coder"),
            "summary": .string("Finished"),
        ]))
        XCTAssertEqual(store.rows[0].text, "↩ Sub-agent report: Finished")
        XCTAssertNil(store.rows[0].noticeReport)
    }

    func testUnknownNoticeKindsAreIgnored() {
        let store = ChatStore()
        store.apply(event(1, "notice", ["kind": .string("mystery"), "summary": .string("?" )]))
        XCTAssertTrue(store.rows.isEmpty)
    }

    func testPlainTextNoticeStillRendersWithTime() {
        let store = ChatStore()
        store.apply(event(1, "notice", ["text": .string("moved to B")]))
        XCTAssertEqual(store.rows[0].kind, .notice)
        XCTAssertEqual(store.rows[0].text, "moved to B")
        XCTAssertEqual(store.rows[0].timestamp, Formatting.timestamp("2026-11-09T10:00:00Z"))
    }

    func testMarkEditedOnlyTouchesUserRows() {
        let store = ChatStore()
        store.apply(event(1, "user", ["text": .string("hello")]))
        store.apply(event(2, "text_delta", ["text": .string("hi")]))
        let user = store.rows[0]
        let assistant = store.rows[1]
        XCTAssertFalse(user.edited)

        store.markEdited(id: user.id)
        XCTAssertTrue(store.rows[0].edited)
        XCTAssertFalse(store.rows[1].edited)

        store.markEdited(id: assistant.id)
        XCTAssertFalse(store.rows[1].edited)
    }
}
