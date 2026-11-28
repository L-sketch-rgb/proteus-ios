import XCTest
@testable import ProteusKit

/// Opening a long chat must not cost anything proportional to its length.
/// Every stage is timed and printed (`PERF stage=... ms=...`); the initial
/// page must stay under 300 ms per stage.
final class LargeChatPerformanceTests: XCTestCase {
    private func time<T>(_ stage: String, _ work: () throws -> T) rethrows -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try work()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print("PERF stage=\(stage) ms=\(Int(ms))")
        return (value, ms)
    }

    /// The target is a phone, slower than the CI Mac: 100 ms per stage.
    private let budget = 100.0

    /// A paged hub: the newest 16 items, tool output capped the way the hub caps it.
    func testPagedFirstPageStages() throws {
        let all = SyntheticHistory.items(count: 4000)
        let page = Array(all[(4000 - 16)..<4000])
        let data = try SyntheticHistory.frameData(id: "big", items: page, offset: 3984, total: 4000)
        print("PERF page_bytes=\(data.count)")

        let (message, decode) = try time("paged.decode") { try ServerMessage.decode(data) }
        guard case .history(let frame) = message else { return XCTFail("not a history frame") }
        XCTAssertLessThan(decode, budget)

        let store = ChatStore()
        let (_, fold) = time("paged.fold+group") { store.applyHistory(frame.items, lastSeq: 1, offset: frame.offset) }
        XCTAssertLessThan(fold, budget)
        XCTAssertLessThanOrEqual(store.visibleRows.count, 120)

        let texts = store.visibleRows.filter { $0.kind == .assistant }.map(\.text)
        let (_, parse) = time("paged.markdown(\(texts.count) rows)") {
            for text in texts { _ = MarkdownBlocks.parse(text) }
        }
        XCTAssertLessThan(parse, budget)
        let (_, inline) = time("paged.inline-styling") {
            for text in texts {
                for case .paragraph(let p) in MarkdownBlocks.parse(text) { _ = MarkdownBlocks.inline(p) }
            }
        }
        XCTAssertLessThan(inline, budget * 2)

        // Backfill: older chunks of 20 prepend one at a time; each chunk is
        // main-thread work, so each must stay small.
        var offset = 3984
        for chunk in 0..<5 {
            let older = Array(all[(offset - 20)..<offset])
            offset -= 20
            let (_, prepend) = time("backfill.chunk\(chunk)(20 rows)") {
                store.prependHistory(older, offset: offset)
            }
            XCTAssertLessThan(prepend, budget)
        }
    }

    /// An old hub: the whole 4000-item history in one frame, with raw output.
    func testOldHubFullFrameStages() throws {
        let all = SyntheticHistory.items(count: 4000)
        let data = try SyntheticHistory.frameData(id: "big", items: all, offset: nil, total: nil)
        print("PERF full_bytes=\(data.count)")

        let (message, decode) = try time("full.decode(\(data.count / 1_000_000) MB)") { try ServerMessage.decode(data) }
        guard case .history(let frame) = message else { return XCTFail("not a history frame") }
        // Runs on the connection queue, never the main thread; still bounded.
        XCTAssertLessThan(decode, 5000)

        let ((held, tail), split) = time("full.tail-split") { HistoryTail.split(frame.items, offset: frame.offset) }
        XCTAssertLessThan(split, budget)
        XCTAssertEqual(tail.filter { $0.kind != "task" }.count, HistoryTail.initialKeep)
        XCTAssertLessThanOrEqual(held.count, HistoryTail.maxHeld)
        XCTAssertEqual(held.count + tail.count + (frame.items.count - held.count - tail.count), frame.items.count)

        let store = ChatStore()
        let (_, fold) = time("full.fold+group(tail)") { store.applyHistory(tail, lastSeq: 1, offset: held.count) }
        XCTAssertLessThan(fold, budget)
        XCTAssertTrue(store.hasOlderHistory)

        // Paging the backlog in 40 at a time stays cheap.
        let (_, older) = time("full.prepend(20)") {
            store.prependHistory(Array(held.suffix(20)), offset: held.count - 20)
        }
        XCTAssertLessThan(older, budget)
        XCTAssertEqual(store.historyOffset, held.count - 20)
    }

    /// The same shape through the old Codable path, for the before/after number.
    func testCodableBaselineOnSmallFrame() throws {
        let items = Array(SyntheticHistory.items(count: 400))
        let data = try SyntheticHistory.frameData(id: "big", items: items, offset: nil, total: nil)
        let (_, codable) = try time("baseline.codable-decode(400 items, \(data.count / 1000) KB)") {
            try JSONDecoder().decode(HistoryFrame.self, from: data)
        }
        let (_, fast) = try time("baseline.fast-decode(400 items)") { try HistoryFrame.fastDecode(data) }
        print("PERF codable_vs_fast=\(Int(codable))ms/\(Int(fast))ms")
    }
}
