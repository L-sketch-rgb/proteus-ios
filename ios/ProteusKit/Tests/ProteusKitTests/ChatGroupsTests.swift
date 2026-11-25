import XCTest
@testable import ProteusKit

final class ChatGroupsTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Fixed "now": 24 Nov 2026, 12:00 UTC.
    private var now: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 11
        components.day = 24
        components.hour = 12
        return calendar.date(from: components)!
    }

    private func iso(_ secondsAgo: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: now.addingTimeInterval(-secondsAgo))
    }

    private func session(
        _ id: String,
        status: String = "idle",
        updatedSecondsAgo: TimeInterval
    ) -> SessionInfo {
        SessionInfo(
            id: id,
            title: id,
            cwd: "/home/user/code/proteus",
            model: "opus",
            status: status,
            updatedAt: iso(updatedSecondsAgo)
        )
    }

    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400

    // MARK: - Project slot

    func testRecentChatIsActiveAndAWeekOldChatIsOlder() {
        let recent = session("recent", updatedSecondsAgo: 2 * hour)
        let old = session("old", updatedSecondsAgo: 9 * day)

        let groups = ChatGroups.groups(
            for: [recent, old],
            scope: .project,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(groups.map(\.kind), [.active, .older])
        XCTAssertEqual(groups[0].sessions.map(\.id), ["recent"])
        XCTAssertEqual(groups[1].sessions.map(\.id), ["old"])
        XCTAssertTrue(groups[1].collapsible)
        XCTAssertTrue(groups[1].collapsedByDefault)
        XCTAssertFalse(groups[0].collapsible)
    }

    func testAnOldChatThatNeedsYouStaysOutOfOlder() {
        let waiting = session("waiting", status: "waiting", updatedSecondsAgo: 30 * day)
        let failed = session("failed", status: "error", updatedSecondsAgo: 30 * day)
        let old = session("old", updatedSecondsAgo: 30 * day)

        let groups = ChatGroups.groups(for: [waiting, failed, old], scope: .project, now: now, calendar: calendar)

        XCTAssertEqual(groups.first?.kind, .needsYou)
        XCTAssertEqual(Set(groups[0].sessions.map(\.id)), ["waiting", "failed"])
        XCTAssertEqual(groups.last?.kind, .older)
        XCTAssertEqual(groups.last?.sessions.map(\.id), ["old"])
    }

    func testUnreadChatNeedsYou() {
        let unread = session("unread", updatedSecondsAgo: 2 * day)
        let seenAt = now.addingTimeInterval(-3 * day)

        let groups = ChatGroups.groups(
            for: [unread],
            scope: .project,
            now: now,
            calendar: calendar,
            lastSeen: { _ in seenAt }
        )

        XCTAssertEqual(groups.map(\.kind), [.needsYou])
    }

    func testChatNeverSeenOnThisDeviceIsNotUnread() {
        let chat = session("fresh", updatedSecondsAgo: 2 * day)

        let groups = ChatGroups.groups(
            for: [chat],
            scope: .project,
            now: now,
            calendar: calendar,
            lastSeen: { _ in nil }
        )

        XCTAssertEqual(groups.map(\.kind), [.active])
    }

    func testRunningChatIsActiveWhateverItsAge() {
        let running = session("running", status: "running", updatedSecondsAgo: 20 * day)

        let groups = ChatGroups.groups(for: [running], scope: .project, now: now, calendar: calendar)

        XCTAssertEqual(groups.map(\.kind), [.active])
    }

    func testSevenDayEdgeSplitsActiveFromOlder() {
        let justInside = session("inside", updatedSecondsAgo: 7 * day - 60)
        let justOutside = session("outside", updatedSecondsAgo: 7 * day + 60)

        let groups = ChatGroups.groups(
            for: [justInside, justOutside],
            scope: .project,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(groups.map(\.kind), [.active, .older])
        XCTAssertEqual(groups[0].sessions.map(\.id), ["inside"])
        XCTAssertEqual(groups[1].sessions.map(\.id), ["outside"])
    }

    func testEmptyGroupsAreDropped() {
        let groups = ChatGroups.groups(for: [], scope: .project, now: now, calendar: calendar)
        XCTAssertTrue(groups.isEmpty)
    }

    func testGroupsAreNewestFirst() {
        let olderActive = session("a", updatedSecondsAgo: 2 * day)
        let newerActive = session("b", updatedSecondsAgo: hour)

        let groups = ChatGroups.groups(
            for: [olderActive, newerActive],
            scope: .project,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(groups[0].sessions.map(\.id), ["b", "a"])
    }

    // MARK: - Chats (one-off) slot

    func testOneOffSplitsTodayThisWeekAndOlder() {
        let today = session("today", updatedSecondsAgo: hour)
        let thisWeek = session("week", updatedSecondsAgo: 3 * day)
        let older = session("older", updatedSecondsAgo: 30 * day)

        let groups = ChatGroups.groups(
            for: [today, thisWeek, older],
            scope: .oneOff,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(groups.map(\.kind), [.today, .thisWeek, .older])
        XCTAssertEqual(groups[0].sessions.map(\.id), ["today"])
        XCTAssertEqual(groups[1].sessions.map(\.id), ["week"])
        XCTAssertEqual(groups[2].sessions.map(\.id), ["older"])
        XCTAssertTrue(groups[2].collapsedByDefault)
    }

    func testAnOldOneOffThatNeedsYouSitsInToday() {
        let waiting = session("waiting", status: "waiting", updatedSecondsAgo: 40 * day)

        let groups = ChatGroups.groups(for: [waiting], scope: .oneOff, now: now, calendar: calendar)

        XCTAssertEqual(groups.map(\.kind), [.today])
    }
}
