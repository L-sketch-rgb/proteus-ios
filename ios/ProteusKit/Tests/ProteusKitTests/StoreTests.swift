import XCTest
@testable import ProteusKit

final class SessionStoreTests: XCTestCase {
    private func session(
        _ id: String,
        title: String? = nil,
        project: String = "",
        cwd: String = "/home/user/work",
        model: String = "claude/opus",
        updatedAt: String
    ) -> SessionInfo {
        SessionInfo(id: id, title: title ?? id, cwd: cwd, project: project, model: model, updatedAt: updatedAt)
    }

    func testNewestFirstOrdering() {
        let store = SessionStore()
        store.replace(sessions: [
            session("old", updatedAt: "2026-11-08T08:00:00Z"),
            session("new", updatedAt: "2026-11-08T10:00:00Z"),
            session("mid", updatedAt: "2026-11-08T09:00:00Z"),
        ])
        XCTAssertEqual(store.sessions.map(\.id), ["new", "mid", "old"])
    }

    func testUpsertKeepsOrderingAndDedupes() {
        let store = SessionStore()
        store.replace(sessions: [
            session("a", updatedAt: "2026-11-08T08:00:00Z"),
            session("b", updatedAt: "2026-11-08T09:00:00Z"),
        ])
        store.upsert(session("a", updatedAt: "2026-11-08T11:00:00Z"))
        XCTAssertEqual(store.sessions.map(\.id), ["a", "b"])
        XCTAssertEqual(store.sessions.count, 2)
    }

    func testGroupingProjectsFirstThenUngroupedChats() {
        let store = SessionStore()
        let defs = [
            ProjectDef(name: "Proteus"),
            ProjectDef(name: "Website"),
            ProjectDef(name: "Zeta"),
            ProjectDef(name: "Alpha"),
        ]
        store.setProjects(defs)
        store.replace(sessions: [
            session("p1", project: "Proteus", updatedAt: "2026-11-08T10:00:00Z"),
            session("p2", project: "Proteus", updatedAt: "2026-11-08T09:00:00Z"),
            session("c1", project: "Website", updatedAt: "2026-11-08T07:00:00Z"),
            session("u1", updatedAt: "2026-11-08T11:00:00Z"),
            session("u2", updatedAt: "2026-11-08T06:00:00Z"),
        ])
        let listing = store.listing()
        XCTAssertEqual(listing.projects.map(\.name), ["Proteus", "Website", "Alpha", "Zeta"])
        XCTAssertEqual(listing.projects[0].sessions.map(\.id), ["p1", "p2"])
        XCTAssertEqual(listing.projects[1].sessions.map(\.id), ["c1"])
        XCTAssertEqual(listing.projects[2].sessions.count, 0)
        XCTAssertEqual(listing.projects[3].sessions.count, 0)
        XCTAssertEqual(listing.chats.map(\.id), ["u1", "u2"])
    }

    func testUnknownProjectFallsBackToChats() {
        let store = SessionStore()
        store.setProjects([ProjectDef(name: "Known")])
        store.replace(sessions: [session("s", project: "Gone", updatedAt: "2026-11-08T10:00:00Z")])
        let listing = store.listing()
        XCTAssertEqual(listing.projects.count, 1) // the empty known project
        XCTAssertEqual(listing.chats.map(\.id), ["s"])
    }

    func testSearchAcrossTitleFolderAndProject() {
        let store = SessionStore()
        store.setProjects([ProjectDef(name: "Proteus")])
        store.replace(sessions: [
            session("a", title: "Fix the hub", project: "Proteus", updatedAt: "2026-11-08T10:00:00Z"),
            session("b", title: "Other", cwd: "/srv/garden", updatedAt: "2026-11-08T09:00:00Z"),
            session("c", title: "Third", updatedAt: "2026-11-08T08:00:00Z"),
        ])
        XCTAssertEqual(store.listing(search: "fix").chats.count, 0)
        XCTAssertEqual(store.listing(search: "fix").projects.first?.sessions.map(\.id), ["a"])
        XCTAssertEqual(store.listing(search: "garden").chats.map(\.id), ["b"])
        XCTAssertEqual(store.listing(search: "proteus").projects.first?.sessions.map(\.id), ["a"])
        XCTAssertEqual(store.listing(search: "  ").projects.first?.sessions.count, 1)
    }

    func testRemoveSession() {
        let store = SessionStore()
        store.replace(sessions: [
            session("a", updatedAt: "2026-11-08T10:00:00Z"),
            session("b", updatedAt: "2026-11-08T09:00:00Z"),
        ])
        store.remove(id: "a")
        XCTAssertEqual(store.sessions.map(\.id), ["b"])
        store.remove(id: "missing") // no change, no crash
        XCTAssertEqual(store.sessions.count, 1)
    }

    func testProjectNamesKeptForOldWelcome() {
        let store = SessionStore()
        store.replace(projectDefs: [], names: ["A", "B"])
        XCTAssertEqual(store.projectNames, ["A", "B"])
    }
}

final class ChatStoreTests: XCTestCase {
    private func event(_ seq: Int, _ kind: String, _ data: [String: JSONValue]) -> HubEvent {
        HubEvent(id: "s1", seq: seq, ts: "2026-11-08T10:00:00Z", kind: kind, data: .object(data))
    }

    private func taskEvent(
        _ seq: Int,
        taskId: String,
        toolUseId: String?,
        status: String,
        tokens: Int? = 10
    ) -> HubEvent {
        HubEvent(id: "s1", seq: seq, ts: "2026-11-08T10:00:00Z", kind: "task", data: taskData(
            taskId: taskId, toolUseId: toolUseId, status: status, tokens: tokens
        ))
    }

    private func taskData(
        taskId: String,
        toolUseId: String?,
        status: String,
        tokens: Int? = 10
    ) -> JSONValue {
        var dict: [String: JSONValue] = [
            "taskId": .string(taskId),
            "agent": .string("coder"),
            "description": .string("write code"),
            "status": .string(status),
            "startedAt": .string("2026-11-08T10:00:00Z"),
        ]
        if let toolUseId { dict["toolUseId"] = .string(toolUseId) }
        if let tokens { dict["tokens"] = .int(tokens) }
        return .object(dict)
    }

    func testTextDeltasAccumulateIntoOneStreamingRow() {
        let store = ChatStore()
        store.apply(event(1, "text_delta", ["text": .string("Hel")]))
        store.apply(event(2, "text_delta", ["text": .string("lo")]))
        XCTAssertEqual(store.rows.count, 1)
        XCTAssertEqual(store.rows[0].kind, .assistant)
        XCTAssertEqual(store.rows[0].text, "Hello")
        XCTAssertTrue(store.rows[0].streaming)
        XCTAssertEqual(store.lastSeq, 2)
    }

    func testThinkingDeltaIsSeparateRow() {
        let store = ChatStore()
        store.apply(event(1, "text_delta", ["text": .string("answer")]))
        store.apply(event(2, "thinking_delta", ["text": .string("hmm")]))
        XCTAssertEqual(store.rows.map(\.kind), [.assistant, .thinking])
        XCTAssertEqual(store.rows[1].text, "hmm")
    }

    func testUserClearsStreaming() {
        let store = ChatStore()
        store.apply(event(1, "text_delta", ["text": .string("partial")]))
        store.apply(event(2, "user", ["text": .string("again")]))
        XCTAssertEqual(store.rows.map(\.kind), [.assistant, .user])
        XCTAssertFalse(store.rows[0].streaming)
        XCTAssertEqual(store.rows[1].text, "again")
    }

    func testUserImageCount() {
        let store = ChatStore()
        store.apply(event(1, "user", ["text": .string("look"), "images": .int(2)]))
        XCTAssertEqual(store.rows[0].images, 2)
    }

    func testAssistantFinalReplacesDeltasAndMakesBlocks() {
        let store = ChatStore()
        store.apply(event(1, "text_delta", ["text": .string("streamed")]))
        let blocks: JSONValue = .array([
            .object(["type": .string("text"), "text": .string("Final")]),
            .object(["type": .string("thinking"), "text": .string("reasoning")]),
            .object([
                "type": .string("tool_use"),
                "id": .string("tool-1"),
                "name": .string("Bash"),
                "input": .object(["command": .string("swift build\nmore")]),
            ]),
        ])
        store.apply(event(2, "assistant", ["blocks": blocks]))
        XCTAssertEqual(store.rows.map(\.kind), [.assistant, .thinking, .tool])
        XCTAssertEqual(store.rows[0].text, "Final")
        XCTAssertFalse(store.rows[0].streaming)
        XCTAssertEqual(store.rows[2].toolId, "tool-1")
        XCTAssertEqual(store.rows[2].toolName, "Bash")
        XCTAssertEqual(store.rows[2].toolSummary, "swift build")
        XCTAssertFalse(store.rows[2].toolDone)
    }

    func testToolResultAttachesToMatchingTool() {
        let store = ChatStore()
        let blocks: JSONValue = .array([.object([
            "type": .string("tool_use"),
            "id": .string("tool-1"),
            "name": .string("Read"),
            "input": .object(["file_path": .string("/tmp/a")]),
        ])])
        store.apply(event(1, "assistant", ["blocks": blocks]))
        store.apply(event(2, "tool_result", [
            "toolUseId": .string("tool-1"),
            "isError": .bool(true),
            "text": .string("permission denied"),
        ]))
        XCTAssertEqual(store.rows[0].toolResult, "permission denied")
        XCTAssertTrue(store.rows[0].toolError)
        XCTAssertTrue(store.rows[0].toolDone)
    }

    func testResultAndErrorRows() {
        let ok = ChatStore()
        ok.apply(event(1, "result", ["ok": .bool(true), "durationMs": .int(1000)]))
        XCTAssertTrue(ok.rows.isEmpty)

        ok.apply(event(2, "result", [
            "ok": .bool(false),
            "durationMs": .int(1000),
            "error": .string("boom"),
        ]))
        XCTAssertEqual(ok.rows.last?.kind, .error)
        XCTAssertEqual(ok.rows.last?.text, "boom")

        let rate = ChatStore()
        rate.apply(event(1, "error", [
            "message": .string("limit reached"),
            "code": .string("rate_limit"),
        ]))
        XCTAssertEqual(rate.rows.last?.text, "limit reached — switch account in Settings.")
    }

    func testNoticeAndStatus() {
        let store = ChatStore()
        store.apply(event(1, "status", ["status": .string("running")]))
        XCTAssertTrue(store.rows.isEmpty)
        store.apply(event(2, "notice", ["text": .string("moved to B")]))
        XCTAssertEqual(store.rows.last?.kind, .notice)
        XCTAssertEqual(store.lastSeq, 2)
    }

    func testSeqGuardIgnoresReplayedEvents() {
        let store = ChatStore()
        store.apply(event(5, "user", ["text": .string("first")]))
        store.apply(event(5, "user", ["text": .string("duplicate")]))
        store.apply(event(3, "user", ["text": .string("older")]))
        XCTAssertEqual(store.rows.count, 1)
        XCTAssertEqual(store.rows[0].text, "first")
        XCTAssertEqual(store.lastSeq, 5)
    }

    func testTaskEventUpdatesRowMatchedByToolUseId() {
        let store = ChatStore()
        let blocks: JSONValue = .array([.object([
            "type": .string("tool_use"),
            "id": .string("tool-9"),
            "name": .string("Task"),
            "input": .object(["description": .string("research")]),
        ])])
        store.apply(event(1, "assistant", ["blocks": blocks]))
        store.apply(taskEvent(2, taskId: "t1", toolUseId: "tool-9", status: "running"))
        XCTAssertEqual(store.tasks.count, 1)
        XCTAssertEqual(store.rows[0].task?.taskId, "t1")
        XCTAssertEqual(store.runningTaskCount, 1)

        store.apply(taskEvent(3, taskId: "t1", toolUseId: "tool-9", status: "completed", tokens: 500))
        XCTAssertEqual(store.rows[0].task?.status, "completed")
        XCTAssertEqual(store.rows[0].task?.tokens, 500)
        XCTAssertEqual(store.runningTaskCount, 0)
    }

    func testTaskBeforeToolUseAttachesWhenBlockArrives() {
        let store = ChatStore()
        store.apply(taskEvent(1, taskId: "t1", toolUseId: "tool-3", status: "running"))
        XCTAssertTrue(store.rows.isEmpty)
        let blocks: JSONValue = .array([.object([
            "type": .string("tool_use"),
            "id": .string("tool-3"),
            "name": .string("Task"),
            "input": .object([:]),
        ])])
        store.apply(event(2, "assistant", ["blocks": blocks]))
        XCTAssertEqual(store.rows[0].task?.taskId, "t1")
    }

    func testNestedEventsAreMarked() {
        let store = ChatStore()
        store.apply(event(1, "text_delta", ["text": .string("sub"), "parent": .string("tool-1")]))
        XCTAssertTrue(store.rows[0].nested)
    }

    func testHistoryBuildThenLiveContinuation() {
        let store = ChatStore()
        let items = [
            HistoryItem(ts: "", kind: "user", data: .object(["text": .string("hi")])),
            HistoryItem(ts: "", kind: "assistant", data: .object(["blocks": .array([
                .object(["type": .string("text"), "text": .string("hello")]),
            ])])),
        ]
        store.applyHistory(items, lastSeq: 10)
        XCTAssertEqual(store.rows.map(\.kind), [.user, .assistant])
        XCTAssertEqual(store.lastSeq, 10)

        store.apply(event(10, "user", ["text": .string("dup")]))
        XCTAssertEqual(store.rows.count, 2)
        store.apply(event(11, "user", ["text": .string("new")]))
        XCTAssertEqual(store.rows.count, 3)
        XCTAssertEqual(store.rows.last?.text, "new")
    }

    func testTaskDataAllowsUnknownNumbers() {
        let store = ChatStore()
        let task: JSONValue = .object([
            "taskId": .string("t1"),
            "agent": .string("agent"),
            "description": .string("done"),
            "status": .string("completed"),
            "startedAt": .string("2026-11-08T10:00:00Z"),
        ])
        store.apply(HubEvent(id: "s1", seq: 1, ts: "", kind: "task", data: task))
        XCTAssertNil(store.tasks["t1"]?.tokens)
        XCTAssertNil(store.tasks["t1"]?.durationMs)
    }
}

final class ModelCatalogTests: XCTestCase {
    private func model(
        _ id: String,
        provider: String = "claude",
        available: Bool = true,
        pinned: Bool? = nil,
        reason: String? = nil
    ) -> ModelInfo {
        ModelInfo(
            id: id,
            label: id,
            provider: provider,
            engineModel: id,
            available: available,
            unavailableReason: reason,
            pinned: pinned
        )
    }

    func testAliasesTopLevelDatedAndUnavailableUnderMore() {
        let catalog = ModelCatalog(models: [
            model("claude/opus", pinned: false),
            model("claude/sonnet", pinned: false),
            model("claude/opus-5-5", pinned: true),
            model("claude/haiku", available: false, reason: "credits"),
            model("deepseek/flash", provider: "deepseek"),
        ], defaultModel: "claude/opus")

        let menu = catalog.menu()
        XCTAssertEqual(menu.sections.map(\.provider), ["claude", "deepseek"])
        XCTAssertEqual(menu.sections[0].models.map(\.id), ["claude/opus", "claude/sonnet"])
        XCTAssertEqual(menu.sections[1].models.map(\.id), ["deepseek/flash"])
        XCTAssertEqual(menu.more.count, 1)
        XCTAssertEqual(menu.more[0].models.map(\.id), ["claude/opus-5-5", "claude/haiku"])
    }

    func testUnavailableNotes() {
        let catalog = ModelCatalog()
        XCTAssertEqual(catalog.note(for: model("a", available: false, reason: "credits")), "Needs usage credits")
        XCTAssertEqual(catalog.note(for: model("b", available: false, reason: "unavailable")), "Unavailable")
        XCTAssertNil(catalog.note(for: model("c")))
    }

    func testNewChatModelHonoursProjectDefault() {
        let catalog = ModelCatalog(models: [
            model("claude/opus"),
            model("deepseek/flash", provider: "deepseek"),
        ], defaultModel: "claude/opus")
        XCTAssertEqual(catalog.newChatModel(project: nil), "claude/opus")
        XCTAssertEqual(
            catalog.newChatModel(project: ProjectDef(name: "P", defaultModel: "deepseek/flash")),
            "deepseek/flash"
        )
        // An unknown project default is ignored, never sent to the hub.
        XCTAssertEqual(
            catalog.newChatModel(project: ProjectDef(name: "P", defaultModel: "gone/model")),
            "claude/opus"
        )
    }

    func testUnknownStoredModelIsMarked() {
        let catalog = ModelCatalog(models: [model("claude/opus")])
        XCTAssertEqual(catalog.label(for: "claude/opus"), "claude/opus")
        XCTAssertEqual(catalog.label(for: "old/model"), "old/model (unavailable)")
        XCTAssertEqual(catalog.label(for: ""), "—")
        XCTAssertFalse(catalog.isSelectable(id: "old/model"))
    }

    func testProviderTitles() {
        let catalog = ModelCatalog()
        XCTAssertEqual(catalog.prettyProvider("claude"), "Claude")
        XCTAssertEqual(catalog.prettyProvider("deepseek"), "DeepSeek")
        XCTAssertEqual(catalog.prettyProvider("kimi"), "Kimi")
    }
}

final class AccountStoreTests: XCTestCase {
    private func account(
        _ name: String,
        provider: String = "claude",
        kind: String = "claude-subscription",
        five: Double? = nil,
        seven: Double? = nil,
        keyHint: String? = nil
    ) -> Account {
        Account(
            name: name,
            label: name.uppercased(),
            provider: provider,
            kind: kind,
            loggedIn: true,
            keyHint: keyHint,
            usage: AccountUsage(
                fiveHour: five.map { UsageWindow(utilization: $0) },
                sevenDay: seven.map { UsageWindow(utilization: $0) }
            )
        )
    }

    func testActiveAccountAndProviders() {
        let store = AccountStore()
        store.replace(accounts: [
            account("a"),
            account("b"),
            account("deepseek", provider: "deepseek", kind: "anthropic-compatible", keyHint: "abcd"),
        ], active: "a")
        XCTAssertEqual(store.activeAccount?.name, "a")
        XCTAssertEqual(store.activeAccount(forProvider: "claude")?.name, "a")
        XCTAssertNil(store.activeAccount(forProvider: "deepseek"))
        XCTAssertEqual(store.providers, ["claude", "deepseek"])
        XCTAssertEqual(store.accounts(forProvider: "claude").map(\.name), ["a", "b"])
    }

    func testUsageRowsUseDashWhenWindowAbsent() {
        let store = AccountStore()
        let partial = account("a", five: 0.42)
        store.replace(accounts: [partial], active: "a")
        let rows = store.usageRows(for: partial)
        XCTAssertEqual(rows.fiveHour, "42%")
        XCTAssertEqual(rows.sevenDay, "—")
    }

    func testKeyHintIsMasked() {
        let store = AccountStore()
        let keyed = account("d", provider: "deepseek", kind: "anthropic-compatible", keyHint: "abcd")
        store.replace(accounts: [keyed], active: "a")
        XCTAssertEqual(store.keyHint(for: keyed), "…abcd")
        XCTAssertNil(store.keyHint(for: account("plain")))
    }

    func testActiveChange() {
        let store = AccountStore()
        store.replace(accounts: [account("a"), account("b")], active: "a")
        store.setActive("b")
        XCTAssertEqual(store.activeAccount?.name, "b")
    }
}

final class TaskStoreTests: XCTestCase {
    private func task(
        _ id: String,
        status: String,
        startedAt: String,
        tokens: Int? = nil,
        durationMs: Int? = nil
    ) -> TaskData {
        TaskData(
            taskId: id,
            agent: "coder",
            description: id,
            status: status,
            startedAt: startedAt,
            tokens: tokens,
            durationMs: durationMs
        )
    }

    func testReplaceReplacesWholeTask() {
        let store = TaskStore()
        store.replace(task("t1", status: "running", startedAt: "2026-11-08T10:00:00Z", tokens: 0, durationMs: 0))
        store.replace(task("t1", status: "completed", startedAt: "2026-11-08T10:00:00Z", tokens: 1200, durationMs: 5000))
        XCTAssertEqual(store.tasks.count, 1)
        XCTAssertEqual(store.tasks["t1"]?.status, "completed")
        XCTAssertEqual(store.tasks["t1"]?.tokens, 1200)
    }

    func testSortingRunningFirstThenNewest() {
        let store = TaskStore()
        store.replace(task("done-old", status: "completed", startedAt: "2026-11-08T08:00:00Z"))
        store.replace(task("run-old", status: "running", startedAt: "2026-11-08T09:00:00Z"))
        store.replace(task("done-new", status: "completed", startedAt: "2026-11-08T10:00:00Z"))
        store.replace(task("run-new", status: "running", startedAt: "2026-11-08T11:00:00Z"))
        XCTAssertEqual(store.sorted.map(\.taskId), ["run-new", "run-old", "done-new", "done-old"])
        XCTAssertEqual(store.runningCount, 2)
        XCTAssertEqual(store.finishedCount, 2)
    }

    func testTotalsIgnoreUnknownNumbers() {
        let store = TaskStore()
        store.replace(task("a", status: "completed", startedAt: "", tokens: 1000, durationMs: 5000))
        store.replace(task("b", status: "completed", startedAt: "", tokens: 12000, durationMs: 70000))
        store.replace(task("c", status: "failed", startedAt: ""))
        XCTAssertEqual(store.totalTokens, 13000)
        XCTAssertEqual(store.totalDurationMs, 75000)
        XCTAssertEqual(store.summaryLine(), "0 running · 3 done · 13.0k tokens · 1:15 total")
    }

    func testLiveDurationForRunningTask() {
        let store = TaskStore()
        let started = "2026-11-08T10:00:00Z"
        store.replace(task("a", status: "running", startedAt: started, durationMs: 100))
        let now = Formatting.parseISO(started)!.addingTimeInterval(42)
        XCTAssertEqual(store.liveDurationMs(for: store.tasks["a"]!, now: now), 42_000)
    }

    func testLookupByToolUse() {
        let store = TaskStore()
        var item = task("a", status: "running", startedAt: "")
        item.toolUseId = "tool-1"
        store.replace(item)
        XCTAssertEqual(store.task(toolUseId: "tool-1")?.taskId, "a")
        XCTAssertNil(store.task(toolUseId: "missing"))
    }
}
