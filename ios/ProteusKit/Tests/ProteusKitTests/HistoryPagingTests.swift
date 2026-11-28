import XCTest
@testable import ProteusKit

final class HistoryPagingTests: XCTestCase {
    private func user(_ text: String) -> HistoryItem {
        HistoryItem(ts: "", kind: "user", data: .object(["text": .string(text)]))
    }

    private func object(_ frame: ClientFrame) throws -> JSONValue {
        try JSONDecoder.proteus.decode(JSONValue.self, from: frame.encoded())
    }

    func testSessionOpenCarriesLimitAndBeforeOnlyWhenGiven() throws {
        let plain = try object(.sessionOpen(id: "s1"))
        XCTAssertNil(plain["limit"])
        XCTAssertNil(plain["before"])
        let page = try object(.sessionOpen(id: "s1", limit: 120, before: 40))
        XCTAssertEqual(page["limit"]?.intValue, 120)
        XCTAssertEqual(page["before"]?.intValue, 40)
    }

    func testHistoryFrameDecodesPagingFieldsAndOlderHubOmitsThem() throws {
        let paged = #"{"t":"history","id":"s1","items":[],"lastSeq":4,"offset":30,"total":150,"older":true}"#
        let frame = try JSONDecoder().decode(HistoryFrame.self, from: Data(paged.utf8))
        XCTAssertEqual(frame.offset, 30)
        XCTAssertEqual(frame.total, 150)
        XCTAssertTrue(frame.older)

        let legacy = #"{"t":"history","id":"s1","items":[],"lastSeq":4}"#
        let old = try JSONDecoder().decode(HistoryFrame.self, from: Data(legacy.utf8))
        XCTAssertNil(old.offset)
        XCTAssertFalse(old.older)
    }

    func testPrependKeepsLiveRowsAndTracksOffset() {
        let store = ChatStore()
        store.applyHistory([user("c"), user("d")], lastSeq: 7, offset: 2)
        XCTAssertTrue(store.hasOlderHistory)
        XCTAssertEqual(store.historyOffset, 2)

        store.prependHistory([user("a"), user("b")], offset: 0)
        XCTAssertEqual(store.rows.map(\.text), ["a", "b", "c", "d"])
        XCTAssertFalse(store.hasOlderHistory)
        XCTAssertEqual(store.lastSeq, 7)
        XCTAssertEqual(Set(store.rows.map(\.id)).count, 4, "row ids stay unique")
    }

    func testFullHistoryFromOlderHubHasNothingOlder() {
        let store = ChatStore()
        store.applyHistory([user("a")], lastSeq: 1)
        XCTAssertFalse(store.hasOlderHistory)
    }

    func testStreamingDeltaPatchesLastRowInPlace() {
        let store = ChatStore()
        store.apply(HubEvent(id: "s1", seq: 1, ts: "", kind: "text_delta", data: .object(["text": .string("he")])))
        store.apply(HubEvent(id: "s1", seq: 2, ts: "", kind: "text_delta", data: .object(["text": .string("llo")])))
        XCTAssertEqual(store.rows.count, 1)
        XCTAssertEqual(store.rows[0].text, "hello")
        XCTAssertEqual(store.visibleRows.last?.text, "hello")
    }
}
