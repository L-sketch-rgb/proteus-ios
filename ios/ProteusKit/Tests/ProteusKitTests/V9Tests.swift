import XCTest
@testable import ProteusKit

final class DraftStoreTests: XCTestCase {

    private func object(_ frame: ClientFrame) throws -> JSONValue {
        try JSONDecoder.proteus.decode(JSONValue.self, from: frame.encoded())
    }

    private func makeStore(
        clock: @escaping DraftStore.Clock = Date.init
    ) -> (DraftStore, () -> [() -> Void]) {
        var scheduled: [() -> Void] = []
        let store = DraftStore(
            clientId: "instance-a",
            interval: 0.6,
            remoteWindow: 3,
            clock: clock,
            scheduler: { _, work in scheduled.append(work) }
        )
        return (store, { scheduled })
    }

    func testLocalEditSendsOneDebouncedDraftSet() throws {
        let (store, scheduled) = makeStore()
        var frames: [ClientFrame] = []
        store.onFrame = { frames.append($0) }

        store.setText("hel", for: "s1")
        store.setText("hello", for: "s1")
        XCTAssertTrue(frames.isEmpty)
        XCTAssertEqual(scheduled().count, 2)

        // Fire both timers: only the newest generation wins.
        scheduled().forEach { $0() }
        XCTAssertEqual(frames.count, 1)

        let json = try object(frames[0])
        XCTAssertEqual(json["t"]?.stringValue, "draft.set")
        XCTAssertEqual(json["id"]?.stringValue, "s1")
        XCTAssertEqual(json["text"]?.stringValue, "hello")
        XCTAssertEqual(json["client"]?.stringValue, "instance-a")
        XCTAssertEqual(store.text(for: "s1"), "hello")
        XCTAssertTrue(store.pendingChatIds.isEmpty)
    }

    func testFlushSendsImmediatelyAndStaleTimerIsIgnored() throws {
        let (store, scheduled) = makeStore()
        var frames: [ClientFrame] = []
        store.onFrame = { frames.append($0) }

        store.setText("queued", for: "s1")
        store.flush("s1")
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(try object(frames[0])["text"]?.stringValue, "queued")

        scheduled().forEach { $0() }
        XCTAssertEqual(frames.count, 1)

        // Nothing pending: a second flush is a no-op.
        store.flush("s1")
        XCTAssertEqual(frames.count, 1)
    }

    func testFlushAllSendsEveryPendingChat() throws {
        let (store, _) = makeStore()
        var frames: [ClientFrame] = []
        store.onFrame = { frames.append($0) }

        store.setText("one", for: "s1")
        store.setText("two", for: "s2")
        store.flushAll()
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(Set(frames.compactMap { try? object($0)["id"]?.stringValue }), ["s1", "s2"])
    }

    func testOwnEchoIsIgnored() {
        let (store, _) = makeStore()
        store.apply(DraftFrame(id: "s1", text: "from me", by: "instance-a"))
        XCTAssertEqual(store.text(for: "s1"), "")
    }

    func testRemoteDraftAppliesOnlyWhenNotTypingRecently() {
        var now = Date(timeIntervalSince1970: 1_000)
        let (store, scheduled) = makeStore(clock: { now })

        store.setText("local", for: "s1")
        scheduled().forEach { $0() } // no longer pending, debounce done

        now = now.addingTimeInterval(2)
        store.apply(DraftFrame(id: "s1", text: "remote", by: "instance-b"))
        XCTAssertEqual(store.text(for: "s1"), "local")

        now = now.addingTimeInterval(2) // 4 s after the last keystroke
        store.apply(DraftFrame(id: "s1", text: "remote", by: "instance-b"))
        XCTAssertEqual(store.text(for: "s1"), "remote")
    }

    func testWelcomeDraftsLoadAndEmptyDraftClears() {
        let (store, _) = makeStore()
        store.apply(welcome: [
            "s1": DraftWire(text: "unsent"),
            "s2": DraftWire(text: "other"),
        ])
        XCTAssertEqual(store.text(for: "s1"), "unsent")
        XCTAssertEqual(store.text(for: "s2"), "other")

        // The hub clears the draft after a successful send.
        store.apply(DraftFrame(id: "s1", text: "", by: ""))
        XCTAssertEqual(store.text(for: "s1"), "")
    }

    func testDiscardClearsTextAndPendingFrame() throws {
        let (store, scheduled) = makeStore()
        var frames: [ClientFrame] = []
        store.onFrame = { frames.append($0) }

        store.setText("stale", for: "s1")
        store.discard("s1")
        scheduled().forEach { $0() }
        XCTAssertEqual(store.text(for: "s1"), "")
        XCTAssertTrue(frames.isEmpty)
    }

    func testTextIsPerChat() {
        let (store, _) = makeStore()
        store.setText("a", for: "s1")
        store.setText("b", for: "s2")
        XCTAssertEqual(store.text(for: "s1"), "a")
        XCTAssertEqual(store.text(for: "s2"), "b")
        XCTAssertEqual(store.text(for: "missing"), "")
    }
}

final class QueueAndScheduleTests: XCTestCase {

    private func object(_ frame: ClientFrame) throws -> JSONValue {
        try JSONDecoder.proteus.decode(JSONValue.self, from: frame.encoded())
    }

    // MARK: - Frames

    func testQueueAddOmitsAbsentAt() throws {
        let plain = try object(.queueAdd(id: "s1", text: "next", rid: "r1"))
        XCTAssertEqual(plain["t"]?.stringValue, "queue.add")
        XCTAssertEqual(plain["id"]?.stringValue, "s1")
        XCTAssertEqual(plain["text"]?.stringValue, "next")
        XCTAssertNil(plain["at"])
        XCTAssertEqual(plain["rid"]?.stringValue, "r1")

        let scheduled = try object(.queueAdd(id: "s1", text: "later", at: "2026-11-10T09:00:00Z"))
        XCTAssertEqual(scheduled["at"]?.stringValue, "2026-11-10T09:00:00Z")
    }

    func testQueueUpdateDistinguishesUnchangedNoneAndTime() throws {
        let textOnly = try object(.queueUpdate(qid: "q1", text: "edited"))
        XCTAssertEqual(textOnly["text"]?.stringValue, "edited")
        XCTAssertNil(textOnly["at"])

        let clearTime = try object(.queueUpdate(qid: "q1", at: .none))
        XCTAssertTrue(clearTime["at"]?.isNull ?? false)

        let setTime = try object(.queueUpdate(qid: "q1", at: .at("2026-11-10T09:00:00Z")))
        XCTAssertEqual(setTime["at"]?.stringValue, "2026-11-10T09:00:00Z")
    }

    func testQueueRemoveAndSendNow() throws {
        let remove = try object(.queueRemove(qid: "q1"))
        XCTAssertEqual(remove["t"]?.stringValue, "queue.remove")
        XCTAssertEqual(remove["qid"]?.stringValue, "q1")

        let send = try object(.queueSendNow(qid: "q1"))
        XCTAssertEqual(send["t"]?.stringValue, "queue.sendNow")
        XCTAssertEqual(send["qid"]?.stringValue, "q1")
    }

    // MARK: - Decoding and store

    func testQueueFrameDecodesScheduledAndPlainItems() throws {
        let json = """
        {"t":"queue","id":"s1","items":[
          {"qid":"q1","text":"later","at":"2026-11-10T09:00:00Z","createdAt":"2026-11-09T10:00:00Z"},
          {"qid":"q2","text":"next","at":null,"createdAt":"2026-11-09T10:01:00Z"}
        ]}
        """
        guard case .queue(let frame) = try ServerMessage.decode(Data(json.utf8)) else {
            return XCTFail("expected queue frame")
        }
        XCTAssertEqual(frame.id, "s1")
        XCTAssertEqual(frame.items.count, 2)
        XCTAssertEqual(frame.items[0].qid, "q1")
        XCTAssertTrue(frame.items[0].isScheduled)
        XCTAssertEqual(frame.items[0].scheduledDate, Date(timeIntervalSince1970: 1_794_301_200))
        XCTAssertFalse(frame.items[1].isScheduled)
        XCTAssertNil(frame.items[1].scheduledDate)
    }

    func testQueueStoreAppliesWelcomeAndBroadcasts() throws {
        let store = QueueStore()
        var changes = 0
        store.onChange = { changes += 1 }

        store.apply(welcome: [
            "s1": [QueueItem(qid: "q1", text: "one", createdAt: "2026-11-09T10:00:00Z")],
            "s2": [],
        ])
        XCTAssertEqual(store.count(for: "s1"), 1)
        XCTAssertEqual(store.count(for: "s2"), 0)
        XCTAssertNil(store.queues["s2"], "empty welcome queues are dropped")

        store.apply(QueueFrame(id: "s1", items: [
            QueueItem(qid: "q1", text: "one", createdAt: "2026-11-09T10:00:00Z"),
            QueueItem(qid: "q2", text: "two", at: "2026-11-10T09:00:00Z", createdAt: "2026-11-09T10:01:00Z"),
        ]))
        XCTAssertEqual(store.count(for: "s1"), 2)
        XCTAssertEqual(store.item(qid: "q2")?.text, "two")

        store.apply(QueueFrame(id: "s1", items: []))
        XCTAssertEqual(store.count(for: "s1"), 0)
        XCTAssertNil(store.item(qid: "q1"))
        XCTAssertEqual(changes, 3)
    }

    func testSessionInfoCarriesQueuedAndCommands() throws {
        let json = """
        {"id":"s1","title":"T","cwd":"/p","model":"m","queued":3,
         "commands":["/compact","/review"]}
        """
        let session = try JSONDecoder.proteus.decode(SessionInfo.self, from: Data(json.utf8))
        XCTAssertEqual(session.queued, 3)
        XCTAssertEqual(session.commands, ["/compact", "/review"])

        let legacy = try JSONDecoder.proteus.decode(SessionInfo.self, from: Data(#"{"id":"s2","title":"L","cwd":"/"}"#.utf8))
        XCTAssertEqual(legacy.queued, 0)
        XCTAssertEqual(legacy.commands, [])
    }

    func testOkFrameCarriesQid() throws {
        guard case .ok(let ok) = try ServerMessage.decode(Data(#"{"t":"ok","rid":"r1","qid":"q9"}"#.utf8)) else {
            return XCTFail("expected ok")
        }
        XCTAssertEqual(ok.rid, "r1")
        XCTAssertEqual(ok.qid, "q9")
    }

    // MARK: - Time menu

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// Monday 2026-11-09 10:00 UTC.
    private func fixedNow() -> Date {
        Date(timeIntervalSince1970: 1_794_218_400)
    }

    func testOffsetsResolveToExactISO() {
        let calendar = utcCalendar()
        let now = fixedNow()
        XCTAssertEqual(SchedulePresets.isoString(now), "2026-11-09T10:00:00Z")

        XCTAssertEqual(SchedulePresets.choice(.in15Minutes, now: now, calendar: calendar).iso, "2026-11-09T10:15:00Z")
        XCTAssertEqual(SchedulePresets.choice(.in30Minutes, now: now, calendar: calendar).iso, "2026-11-09T10:30:00Z")
        XCTAssertEqual(SchedulePresets.choice(.in1Hour, now: now, calendar: calendar).iso, "2026-11-09T11:00:00Z")
        XCTAssertEqual(SchedulePresets.choice(.in2Hours, now: now, calendar: calendar).iso, "2026-11-09T12:00:00Z")
        XCTAssertEqual(SchedulePresets.choice(.in4Hours, now: now, calendar: calendar).iso, "2026-11-09T14:00:00Z")
        XCTAssertEqual(SchedulePresets.choice(.tomorrowMorning, now: now, calendar: calendar).iso, "2026-11-10T09:00:00Z")
    }

    func testTonightIsTodayBefore21AndTomorrowAfter() {
        let calendar = utcCalendar()
        let before = fixedNow()
        let tonight = SchedulePresets.choice(.tonight, now: before, calendar: calendar)
        XCTAssertEqual(tonight.iso, "2026-11-09T21:00:00Z")
        XCTAssertEqual(tonight.phrase, "Tonight at 21:00")

        let after = SchedulePresets.time(hour: 22, minute: 0, on: before, calendar: calendar)
        let tomorrow = SchedulePresets.choice(.tonight, now: after, calendar: calendar)
        XCTAssertEqual(tomorrow.iso, "2026-11-10T21:00:00Z")
    }

    func testCustomDatesAreTodayTomorrowAndFiveWeekdays() {
        let options = SchedulePresets.customDates(now: fixedNow(), calendar: utcCalendar())
        XCTAssertEqual(options.map(\.label), [
            "Today", "Tomorrow", "Wednesday", "Thursday", "Friday", "Monday", "Tuesday",
        ])
        XCTAssertEqual(options.count, 7)
        XCTAssertEqual(SchedulePresets.isoString(options[2].date), "2026-11-11T00:00:00Z")
        XCTAssertEqual(SchedulePresets.isoString(options[6].date), "2026-11-17T00:00:00Z")
    }

    func testCustomChoiceUsesLocalHourAndMinuteSteps() {
        let calendar = utcCalendar()
        let now = fixedNow()
        let dates = SchedulePresets.customDates(now: now, calendar: calendar)
        let today = SchedulePresets.customChoice(day: dates[0].date, hour: 14, minute: 30, now: now, calendar: calendar)
        XCTAssertEqual(today.iso, "2026-11-09T14:30:00Z")
        XCTAssertEqual(today.phrase, "Today at 14:30")

        let tomorrow = SchedulePresets.customChoice(day: dates[1].date, hour: 9, minute: 0, now: now, calendar: calendar)
        XCTAssertEqual(tomorrow.iso, "2026-11-10T09:00:00Z")
        XCTAssertEqual(tomorrow.phrase, "Tomorrow at 09:00")

        let later = SchedulePresets.customChoice(day: dates[3].date, hour: 7, minute: 5, now: now, calendar: calendar)
        XCTAssertEqual(later.phrase, "Thursday at 07:05")

        XCTAssertEqual(SchedulePresets.minuteOptions, [0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55])
        XCTAssertEqual(SchedulePresets.hourOptions.first, 0)
        XCTAssertEqual(SchedulePresets.hourOptions.last, 23)
    }
}

final class SlashCommandsTests: XCTestCase {

    func testProteusTableOrderAndNewChatSubset() {
        let rows = SlashCommands.list(engineCommands: [], newChat: false)
        XCTAssertEqual(rows.map(\.name), [
            "/queue", "/schedule", "/model", "/mode", "/stop", "/rename", "/new", "/help",
        ])
        XCTAssertTrue(rows.allSatisfy { $0.group == .proteus })

        let newChat = SlashCommands.list(engineCommands: [], newChat: true)
        XCTAssertEqual(newChat.map(\.name), ["/model", "/mode", "/help"])
    }

    func testEngineCommandsFollowInClaudeCodeGroupWithoutDuplicates() {
        let rows = SlashCommands.list(engineCommands: ["compact", "/review", "/model", "/compact"])
        let engine = rows.filter { $0.group == .engine }
        XCTAssertEqual(engine.map(\.name), ["/compact", "/review"])
        XCTAssertEqual(engine.first?.summary, "Compact the conversation")
        XCTAssertEqual(engine.last?.summary, "Review a pull request")
        // /model stays the app's command only.
        XCTAssertEqual(rows.filter { $0.name == "/model" }.count, 1)
        XCTAssertEqual(rows.first?.group, .proteus)
    }

    func testMenuFiltersByPrefixAndClosesAfterWhitespace() {
        let engine = ["/compact", "/review"]
        XCTAssertEqual(
            SlashCommands.menu(for: "/", engineCommands: engine).map(\.name),
            ["/queue", "/schedule", "/model", "/mode", "/stop", "/rename", "/new", "/help", "/compact", "/review"]
        )
        XCTAssertEqual(
            SlashCommands.menu(for: "/q", engineCommands: engine).map(\.name),
            ["/queue"]
        )
        XCTAssertEqual(
            SlashCommands.menu(for: "/rev", engineCommands: engine).map(\.name),
            ["/review"]
        )
        XCTAssertTrue(SlashCommands.menu(for: "/queue hello", engineCommands: engine).isEmpty)
        XCTAssertTrue(SlashCommands.menu(for: "hello", engineCommands: engine).isEmpty)
    }

    func testParseSplitsCommandAndArgument() {
        let queue = SlashCommands.parse("/queue fix the tests")
        XCTAssertEqual(queue?.command, "/queue")
        XCTAssertEqual(queue?.argument, "fix the tests")

        let bare = SlashCommands.parse("/stop")
        XCTAssertEqual(bare?.command, "/stop")
        XCTAssertEqual(bare?.argument, "")

        XCTAssertNil(SlashCommands.parse("not a command"))
        XCTAssertTrue(SlashCommands.isProteusCommand("/queue"))
        XCTAssertFalse(SlashCommands.isProteusCommand("/compact"))
    }
}

final class NotificationSettingsTests: XCTestCase {

    private func object(_ frame: ClientFrame) throws -> JSONValue {
        try JSONDecoder.proteus.decode(JSONValue.self, from: frame.encoded())
    }

    func testWelcomeCarriesNotificationSettings() throws {
        let json = """
        {"t":"welcome","hubVersion":"9","accounts":[],"active":"","sessions":[],
         "projects":[],"projectDefs":[],"models":[],"defaultModel":"","terms":[],
         "drafts":{},"queues":{},
         "notifications":{"enabled":true,"server":"https://ntfy.example.com","topic":"proteus-abc"}}
        """
        guard case .welcome(let welcome) = try ServerMessage.decode(Data(json.utf8)) else {
            return XCTFail("expected welcome")
        }
        let settings = try XCTUnwrap(welcome.notifications)
        XCTAssertTrue(settings.enabled)
        XCTAssertEqual(settings.server, "https://ntfy.example.com")
        XCTAssertEqual(settings.topic, "proteus-abc")
        XCTAssertEqual(settings.postURL?.absoluteString, "https://ntfy.example.com/proteus-abc")
    }

    func testNotificationBroadcastUpdatesStore() throws {
        let store = NotificationStore()
        var changes = 0
        store.onChange = { changes += 1 }

        let json = #"{"t":"notifications","enabled":true,"server":"https://ntfy.sh","topic":"proteus-xyz"}"#
        guard case .notifications(let frame) = try ServerMessage.decode(Data(json.utf8)) else {
            return XCTFail("expected notifications")
        }
        store.apply(frame)
        XCTAssertTrue(store.isEnabled)
        XCTAssertEqual(store.settings.topic, "proteus-xyz")
        XCTAssertEqual(changes, 1)
    }

    func testSetAndTestFramesOmitAbsentFields() throws {
        let enable = try object(NotificationStore.setFrame(enabled: true))
        XCTAssertEqual(enable["t"]?.stringValue, "notifications.set")
        XCTAssertEqual(enable["enabled"]?.boolValue, true)
        XCTAssertNil(enable["server"])
        XCTAssertNil(enable["regenerate"])

        let all = try object(NotificationStore.setFrame(enabled: false, server: "https://ntfy.sh", regenerate: true))
        XCTAssertEqual(all["enabled"]?.boolValue, false)
        XCTAssertEqual(all["server"]?.stringValue, "https://ntfy.sh")
        XCTAssertEqual(all["regenerate"]?.boolValue, true)

        let test = try object(NotificationStore.testFrame())
        XCTAssertEqual(test["t"]?.stringValue, "notifications.test")
    }

    func testSubscribeURLIsAnNtfyDeepLink() {
        XCTAssertEqual(
            NotificationSettings.subscribeURL(server: "https://ntfy.sh", topic: "proteus-abc")?.absoluteString,
            "ntfy://ntfy.sh/proteus-abc"
        )
        XCTAssertEqual(
            NotificationSettings.subscribeURL(server: "https://ntfy.example.com:8443/base/", topic: "t1")?.absoluteString,
            "ntfy://ntfy.example.com:8443/base/t1"
        )
        XCTAssertNil(NotificationSettings.subscribeURL(server: "https://ntfy.sh", topic: ""))
        XCTAssertNil(NotificationSettings.subscribeURL(server: "ftp://ntfy.sh", topic: "t1"))
    }
}

final class FinishedAgentGroupingTests: XCTestCase {

    private func task(
        _ id: String,
        _ status: String,
        started: String
    ) -> TaskData {
        TaskData(taskId: id, agent: "agent", description: id, status: status, startedAt: started)
    }

    func testRunningAndFinishedAreSeparatedNewestFirst() {
        let store = TaskStore()
        store.replace(task("done-old", "completed", started: "2026-11-09T08:00:00Z"))
        store.replace(task("running", "running", started: "2026-11-09T09:00:00Z"))
        store.replace(task("failed", "failed", started: "2026-11-09T10:00:00Z"))
        store.replace(task("stopped", "stopped", started: "2026-11-09T07:00:00Z"))
        store.replace(task("done-new", "completed", started: "2026-11-09T11:00:00Z"))

        XCTAssertEqual(store.running.map(\.taskId), ["running"])
        XCTAssertEqual(store.finished.map(\.taskId), ["done-new", "failed", "done-old", "stopped"])
        XCTAssertEqual(store.runningCount, 1)
        XCTAssertEqual(store.finishedCount, 4)
        // The collapsed default only hides the finished group; running stays.
        XCTAssertEqual(store.sorted.map(\.taskId), ["running", "done-new", "failed", "done-old", "stopped"])
    }
}
