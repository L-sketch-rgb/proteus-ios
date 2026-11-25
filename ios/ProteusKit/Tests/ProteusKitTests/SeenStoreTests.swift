import XCTest
@testable import ProteusKit

final class SeenStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "proteus.seen.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func iso(_ secondsAgo: TimeInterval, from now: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: now.addingTimeInterval(-secondsAgo))
    }

    private func session(_ id: String, status: String = "idle", updated: String) -> SessionInfo {
        SessionInfo(id: id, title: id, cwd: "/home/user", model: "opus", status: status, updatedAt: updated)
    }

    func testNeverSeenChatIsNotUnread() {
        let store = SeenStore(defaults: defaults)
        let chat = session("a", updated: iso(60))
        XCTAssertFalse(store.isUnread(chat))
    }

    func testUpdateAfterLastSeenIsUnread() {
        let now = Date()
        let store = SeenStore(defaults: defaults)
        store.markSeen("a", at: now.addingTimeInterval(-3_600))
        let chat = session("a", updated: iso(60, from: now))
        XCTAssertTrue(store.isUnread(chat))
    }

    func testUpdateBeforeLastSeenIsRead() {
        let now = Date()
        let store = SeenStore(defaults: defaults)
        store.markSeen("a", at: now)
        let chat = session("a", updated: iso(3_600, from: now))
        XCTAssertFalse(store.isUnread(chat))
    }

    func testBusyChatsAreNeverUnread() {
        let now = Date()
        let store = SeenStore(defaults: defaults)
        store.markSeen("running", at: now.addingTimeInterval(-3_600))
        store.markSeen("waiting", at: now.addingTimeInterval(-3_600))
        store.markSeen("error", at: now.addingTimeInterval(-3_600))
        let updated = iso(60, from: now)

        XCTAssertFalse(store.isUnread(session("running", status: "running", updated: updated)))
        XCTAssertFalse(store.isUnread(session("waiting", status: "waiting", updated: updated)))
        XCTAssertFalse(store.isUnread(session("error", status: "error", updated: updated)))
    }

    func testLastSeenRoundTripsThroughUserDefaults() {
        let now = Date()
        let first = SeenStore(defaults: defaults)
        first.markSeen("a", at: now)
        first.markSeen(["b", "c"], at: now)

        let second = SeenStore(defaults: defaults)
        XCTAssertEqual(second.lastSeen("a")?.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(second.lastSeen("b")?.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNotNil(second.lastSeen("c"))
        XCTAssertNil(second.lastSeen("d"))
    }

    func testMarkSeenKeepsOtherChats() {
        let now = Date()
        let store = SeenStore(defaults: defaults)
        store.markSeen("a", at: now.addingTimeInterval(-100))
        store.markSeen("b", at: now)
        XCTAssertNotNil(store.lastSeen("a"))
        XCTAssertNotNil(store.lastSeen("b"))
    }

    func testPruneDropsChatsTheHubNoLongerHas() {
        let store = SeenStore(defaults: defaults)
        store.markSeen(["a", "b", "c"])
        store.prune(keeping: ["a", "c"])
        XCTAssertNotNil(store.lastSeen("a"))
        XCTAssertNil(store.lastSeen("b"))
        XCTAssertNotNil(store.lastSeen("c"))
    }

    func testUnknownStatusDoesNotCrash() {
        let now = Date()
        let store = SeenStore(defaults: defaults)
        store.markSeen("a", at: now.addingTimeInterval(-3_600))
        let chat = session("a", status: "something-new", updated: iso(60, from: now))
        // Unknown statuses decode as idle, which can be unread.
        XCTAssertTrue(store.isUnread(chat))
    }
}
