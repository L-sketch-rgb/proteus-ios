import XCTest
@testable import ProteusKit

final class FrameTests: XCTestCase {

    private func decoded(_ json: String) throws -> JSONValue {
        try JSONDecoder.proteus.decode(JSONValue.self, from: Data(json.utf8))
    }

    private func object(_ frame: ClientFrame) throws -> JSONValue {
        try JSONDecoder.proteus.decode(JSONValue.self, from: frame.encoded())
    }

    // MARK: - Encoding requests (protocol.md §2)

    func testHelloEncoding() throws {
        let frame = ClientFrame.hello(token: "s3cret", client: "ios", version: 1)
        let json = try object(frame)
        XCTAssertEqual(json["t"]?.stringValue, "hello")
        XCTAssertEqual(json["token"]?.stringValue, "s3cret")
        XCTAssertEqual(json["client"]?.stringValue, "ios")
        XCTAssertEqual(json["version"]?.intValue, 1)
        XCTAssertNil(json["rid"])
    }

    func testSessionOpenOmitsAbsentSinceAndIncludesItWhenGiven() throws {
        let first = try object(.sessionOpen(id: "s1"))
        XCTAssertEqual(first["t"]?.stringValue, "session.open")
        XCTAssertEqual(first["id"]?.stringValue, "s1")
        XCTAssertNil(first["since"])

        let replay = try object(.sessionOpen(id: "s1", since: 42, rid: "r1"))
        XCTAssertEqual(replay["since"]?.intValue, 42)
        XCTAssertEqual(replay["rid"]?.stringValue, "r1")
    }

    func testSessionNewWithImagesAndProject() throws {
        let images = [ImageIn(mediaType: "image/jpeg", data: "AAA")]
        let frame = try ClientFrame.sessionNew(
            cwd: "/home/user",
            model: "claude/opus",
            text: "hello",
            images: images,
            permissionMode: "acceptEdits",
            project: "Proteus"
        )
        let json = try object(frame)
        XCTAssertEqual(json["cwd"]?.stringValue, "/home/user")
        XCTAssertEqual(json["model"]?.stringValue, "claude/opus")
        XCTAssertEqual(json["text"]?.stringValue, "hello")
        XCTAssertEqual(json["permissionMode"]?.stringValue, "acceptEdits")
        XCTAssertEqual(json["project"]?.stringValue, "Proteus")
        XCTAssertEqual(json["images"]?.arrayValue?.first?["mediaType"]?.stringValue, "image/jpeg")
        XCTAssertEqual(json["images"]?.arrayValue?.first?["data"]?.stringValue, "AAA")
    }

    func testPermissionReplyVariants() throws {
        let deny = try object(.permissionReply(id: "s1", reqId: "p1", allow: false))
        XCTAssertEqual(deny["allow"]?.boolValue, false)
        XCTAssertNil(deny["always"])

        let always = try object(.permissionReply(id: "s1", reqId: "p1", allow: true, always: true))
        XCTAssertEqual(always["allow"]?.boolValue, true)
        XCTAssertEqual(always["always"]?.boolValue, true)
    }

    func testPermissionReplyAnswersAndAnnotations() throws {
        let answer = try object(.permissionReply(
            id: "s1",
            reqId: "q1",
            allow: true,
            answers: ["Pick a colour": "Blue", "Pick toppings": "Olives, Extra"],
            annotations: ["Pick a colour": ["notes": "the first one"]]
        ))
        XCTAssertEqual(answer["answers"]?.objectValue?["Pick a colour"]?.stringValue, "Blue")
        XCTAssertEqual(
            answer["answers"]?.objectValue?["Pick toppings"]?.stringValue,
            "Olives, Extra"
        )
        XCTAssertEqual(
            answer["annotations"]?.objectValue?["Pick a colour"]?.objectValue?["notes"]?.stringValue,
            "the first one"
        )

        let skip = try object(.permissionReply(
            id: "s1",
            reqId: "q1",
            allow: false,
            message: "The user did not answer; continue with your best judgement."
        ))
        XCTAssertEqual(skip["allow"]?.boolValue, false)
        XCTAssertEqual(
            skip["message"]?.stringValue,
            "The user did not answer; continue with your best judgement."
        )
        XCTAssertNil(skip["answers"])
    }

    func testSecretSetNullClearsKey() throws {
        let clear = try object(.secretSet(account: "deepseek", key: nil))
        XCTAssertTrue(clear["key"]?.isNull ?? false)

        let set = try object(.secretSet(account: "deepseek", key: "sk-1234"))
        XCTAssertEqual(set["key"]?.stringValue, "sk-1234")
    }

    func testProjectSaveEncodesDefinition() throws {
        let project = ProjectDef(
            name: "Website",
            cwd: "/home/user/website",
            defaultModel: "claude/opus",
            instructions: "Be precise",
            agentPolicy: "Delegate",
            subagents: [SubagentDef(name: "coder", when: "write code", model: "haiku", tools: "all")]
        )
        let frame = try ClientFrame.projectSave(project: project, oldName: "Old")
        let json = try object(frame)
        XCTAssertEqual(json["t"]?.stringValue, "project.save")
        XCTAssertEqual(json["oldName"]?.stringValue, "Old")
        XCTAssertEqual(json["project"]?["name"]?.stringValue, "Website")
        XCTAssertEqual(json["project"]?["subagents"]?.arrayValue?.first?["tools"]?.stringValue, "all")
    }

    func testAllSimpleRequestTypesRoundTrip() throws {
        let frames: [(ClientFrame, String)] = [
            (.sessionsList(rid: "1"), "sessions.list"),
            (.sessionClose(id: "s"), "session.close"),
            (.sessionDelete(id: "s"), "session.delete"),
            (.sessionInterrupt(id: "s"), "session.interrupt"),
            (.sessionStop(id: "s"), "session.stop"),
            (.sessionSetModel(id: "s", model: "m"), "session.setModel"),
            (.sessionSetMode(id: "s", mode: "plan"), "session.setMode"),
            (.sessionRename(id: "s", title: "t"), "session.rename"),
            (.sessionSetProject(id: "s", project: "P"), "session.setProject"),
            (.projectDelete(name: "P"), "project.delete"),
            (.agentsList(), "agents.list"),
            (.accountSwitch(name: "b"), "account.switch"),
            (.accountLogin(name: "a"), "account.login"),
            (.accountRename(name: "a", label: "A"), "account.rename"),
            (.accountAdd(provider: "claude", name: "c", label: "C"), "account.add"),
            (.accountRemove(name: "a"), "account.remove"),
            (.providerDelete(id: "p"), "provider.delete"),
            (.providerSetActive(provider: "claude", account: "a"), "provider.setActive"),
            (.defaultsSet(model: "claude/opus"), "defaults.set"),
            (.modelsList(), "models.list"),
            (.fsDirs(path: "/"), "fs.dirs"),
            (.termOpen(cwd: nil, cols: 80, rows: 24), "term.open"),
            (.termAttach(id: "t"), "term.attach"),
            (.termInput(id: "t", dataBase64: "aGk="), "term.input"),
            (.termResize(id: "t", cols: 100, rows: 30), "term.resize"),
            (.termClose(id: "t"), "term.close"),
            (.termList(), "term.list"),
            (.ping(), "ping"),
        ]
        for (frame, type) in frames {
            let json = try object(frame)
            XCTAssertEqual(json["t"]?.stringValue, type)
        }
    }

    func testSessionSendEncoding() throws {
        let frame = try ClientFrame.sessionSend(id: "s", text: "hi", images: [ImageIn(mediaType: "image/png", data: "QQ==")])
        let json = try object(frame)
        XCTAssertEqual(json["id"]?.stringValue, "s")
        XCTAssertEqual(json["text"]?.stringValue, "hi")
        XCTAssertEqual(json["images"]?.arrayValue?.count, 1)
    }

    // MARK: - Decoding server frames (protocol.md §1/§3/§5)

    private let welcomeJSON = """
    {"t":"welcome","hubVersion":"0.6.0","accounts":[{"name":"a","label":"Personal","email":"a@example.com","provider":"claude","kind":"claude-subscription","loggedIn":true,"keyHint":null,"usage":{"fiveHour":{"utilization":0.42,"resetsAt":"2026-11-08T12:00:00Z"},"sevenDay":{"utilization":0.1},"status":"allowed"}}],"active":"a","sessions":[{"id":"s1","title":"Demo","cwd":"/home/user","project":"","model":"claude/opus","account":"a","status":"running","mode":"default","updatedAt":"2026-11-08T10:00:00Z","live":true,"agentsRunning":2}],"projects":["P"],"projectDefs":[{"name":"P","subagents":[]}],"models":[{"id":"claude/opus","label":"Opus 5.5","provider":"claude","engine":"claude-code","engineModel":"opus","tier":"top","available":true}],"defaultModel":"claude/opus","terms":[]}
    """

    func testWelcomeDecoding() throws {
        let message = try ServerMessage.decode(Data(welcomeJSON.utf8))
        guard case .welcome(let welcome) = message else { return XCTFail("not welcome") }
        XCTAssertEqual(message.type, "welcome")
        XCTAssertEqual(welcome.hubVersion, "0.6.0")
        XCTAssertEqual(welcome.accounts.count, 1)
        XCTAssertEqual(welcome.accounts[0].usage?.fiveHour?.utilization, 0.42)
        XCTAssertEqual(welcome.accounts[0].usage?.sevenDay?.utilization, 0.1)
        XCTAssertNil(welcome.accounts[0].keyHint)
        XCTAssertEqual(welcome.sessions.count, 1)
        XCTAssertEqual(welcome.sessions[0].agentsRunning, 2)
        XCTAssertEqual(welcome.sessions[0].statusKind, .running)
        XCTAssertEqual(welcome.models.count, 1)
        XCTAssertEqual(welcome.defaultModel, "claude/opus")
        XCTAssertEqual(welcome.projectDefs.first?.name, "P")
        XCTAssertEqual(welcome.terms.count, 0)
    }

    func testWelcomeDefaultsMissingOptionalFields() throws {
        let json = #"{"t":"welcome","accounts":[],"active":"a","sessions":[],"models":[],"defaultModel":""}"#
        let message = try ServerMessage.decode(Data(json.utf8))
        guard case .welcome(let welcome) = message else { return XCTFail("not welcome") }
        XCTAssertEqual(welcome.projects, [])
        XCTAssertEqual(welcome.projectDefs, [])
        XCTAssertEqual(welcome.terms, [])
        XCTAssertNil(welcome.hubVersion)
    }

    func testEventFrameNestedShape() throws {
        let json = #"{"t":"event","event":{"id":"s1","seq":7,"ts":"2026-11-08T10:00:00Z","kind":"text_delta","data":{"text":"Hi"}}}"#
        let message = try ServerMessage.decode(Data(json.utf8))
        guard case .event(let frame) = message else { return XCTFail("not event") }
        XCTAssertEqual(frame.event.id, "s1")
        XCTAssertEqual(frame.event.seq, 7)
        XCTAssertEqual(frame.event.kind, "text_delta")
        XCTAssertEqual(frame.event.data["text"]?.stringValue, "Hi")
    }

    func testEventFrameFlatShape() throws {
        let json = #"{"t":"event","id":"s1","seq":8,"ts":"2026-11-08T10:00:01Z","kind":"user","data":{"text":"x"}}"#
        let message = try ServerMessage.decode(Data(json.utf8))
        guard case .event(let frame) = message else { return XCTFail("not event") }
        XCTAssertEqual(frame.event.seq, 8)
        XCTAssertEqual(frame.event.kind, "user")
    }

    func testSessionUpdatedAndRemoved() throws {
        let updated = #"{"t":"session.updated","session":{"id":"s1","title":"T","cwd":"/","project":"P","model":"claude/opus","account":"a","status":"waiting","mode":"plan","updatedAt":"2026-11-08T10:00:00Z","live":true,"agentsRunning":1}}"#
        guard case .sessionUpdated(let frame) = try ServerMessage.decode(Data(updated.utf8)) else {
            return XCTFail("not session.updated")
        }
        XCTAssertEqual(frame.session.status, "waiting")
        XCTAssertEqual(frame.session.agentsRunning, 1)

        let removed = #"{"t":"session.removed","id":"s1"}"#
        guard case .sessionRemoved(let gone) = try ServerMessage.decode(Data(removed.utf8)) else {
            return XCTFail("not removed")
        }
        XCTAssertEqual(gone.id, "s1")
    }

    func testPermissionFrames() throws {
        let request = #"{"t":"permission.request","id":"s1","reqId":"p1","tool":"Bash","input":{"command":"ls"},"title":"Run a command"}"#
        guard case .permissionRequest(let frame) = try ServerMessage.decode(Data(request.utf8)) else {
            return XCTFail("not permission.request")
        }
        XCTAssertEqual(frame.tool, "Bash")
        XCTAssertEqual(frame.input["command"]?.stringValue, "ls")
        XCTAssertEqual(frame.title, "Run a command")

        let resolved = #"{"t":"permission.resolved","id":"s1","reqId":"p1"}"#
        guard case .permissionResolved(let done) = try ServerMessage.decode(Data(resolved.utf8)) else {
            return XCTFail("not permission.resolved")
        }
        XCTAssertEqual(done.reqId, "p1")
    }

    func testHistoryFrame() throws {
        let json = #"{"t":"history","id":"s1","items":[{"ts":"2026-11-08T10:00:00Z","kind":"user","data":{"text":"hi"}},{"ts":"","kind":"notice","data":{"text":"moved"}}],"lastSeq":3}"#
        guard case .history(let frame) = try ServerMessage.decode(Data(json.utf8)) else {
            return XCTFail("not history")
        }
        XCTAssertEqual(frame.id, "s1")
        XCTAssertEqual(frame.lastSeq, 3)
        XCTAssertEqual(frame.items.count, 2)
        XCTAssertEqual(frame.items[0].kind, "user")
    }

    func testTerminalFrames() throws {
        let opened = #"{"t":"term.opened","rid":"r","term":{"id":"t1","title":"~","cwd":"/home/user","pid":42,"createdAt":"2026-11-08T10:00:00Z","alive":true}}"#
        guard case .termOpened(let frame) = try ServerMessage.decode(Data(opened.utf8)) else {
            return XCTFail("not term.opened")
        }
        XCTAssertEqual(frame.term.pid, 42)
        XCTAssertEqual(frame.rid, "r")

        let output = #"{"t":"term.output","id":"t1","data":"aGk=","replay":true}"#
        guard case .termOutput(let out) = try ServerMessage.decode(Data(output.utf8)) else {
            return XCTFail("not term.output")
        }
        XCTAssertEqual(out.replay, true)
        XCTAssertEqual(out.data, "aGk=")

        let exit = #"{"t":"term.exit","id":"t1","code":0}"#
        guard case .termExit(let ended) = try ServerMessage.decode(Data(exit.utf8)) else {
            return XCTFail("not term.exit")
        }
        XCTAssertEqual(ended.code, 0)

        let terms = #"{"t":"terms","terms":[]}"#
        guard case .terms(let list) = try ServerMessage.decode(Data(terms.utf8)) else {
            return XCTFail("not terms")
        }
        XCTAssertEqual(list.terms.count, 0)
    }

    func testAccountsModelsProjectsAgentsDirsLogin() throws {
        let accounts = #"{"t":"accounts","accounts":[{"name":"a","label":"A","provider":"claude","kind":"claude-subscription","loggedIn":true}],"active":"a"}"#
        guard case .accounts(let acc) = try ServerMessage.decode(Data(accounts.utf8)) else {
            return XCTFail("not accounts")
        }
        XCTAssertEqual(acc.active, "a")

        let models = #"{"t":"models","models":[{"id":"m","label":"M","provider":"p","engine":"claude-code","engineModel":"x","available":false,"unavailableReason":"credits"}]}"#
        guard case .models(let mods) = try ServerMessage.decode(Data(models.utf8)) else {
            return XCTFail("not models")
        }
        XCTAssertEqual(mods.models.first?.unavailableReason, "credits")

        let projects = #"{"t":"projects","projectDefs":[{"name":"P","subagents":[]}],"projects":["P"]}"#
        guard case .projects(let proj) = try ServerMessage.decode(Data(projects.utf8)) else {
            return XCTFail("not projects")
        }
        XCTAssertEqual(proj.projects, ["P"])

        let agents = #"{"t":"agents","agents":[{"name":"coder","description":"writes","source":"user"}]}"#
        guard case .agents(let ag) = try ServerMessage.decode(Data(agents.utf8)) else {
            return XCTFail("not agents")
        }
        XCTAssertEqual(ag.agents.first?.name, "coder")

        let dirs = #"{"t":"dirs","path":"/home/user","dirs":["a","b"]}"#
        guard case .dirs(let dir) = try ServerMessage.decode(Data(dirs.utf8)) else {
            return XCTFail("not dirs")
        }
        XCTAssertEqual(dir.dirs, ["a", "b"])

        let login = #"{"t":"login","name":"a","status":"url","url":"https://example.com"}"#
        guard case .login(let log) = try ServerMessage.decode(Data(login.utf8)) else {
            return XCTFail("not login")
        }
        XCTAssertEqual(log.status, "url")
    }

    func testOkErrPongAndUnknown() throws {
        let ok = #"{"t":"ok","rid":"r1","id":"s9"}"#
        guard case .ok(let frame) = try ServerMessage.decode(Data(ok.utf8)) else {
            return XCTFail("not ok")
        }
        XCTAssertEqual(frame.id, "s9")

        let err = #"{"t":"err","rid":"r1","code":"not_found","message":"nope"}"#
        guard case .err(let failure) = try ServerMessage.decode(Data(err.utf8)) else {
            return XCTFail("not err")
        }
        XCTAssertEqual(failure.code, "not_found")

        guard case .pong = try ServerMessage.decode(Data(#"{"t":"pong"}"#.utf8)) else {
            return XCTFail("not pong")
        }

        let unknown = #"{"t":"future.frame","value":1}"#
        guard case .unknown(let type, let raw) = try ServerMessage.decode(Data(unknown.utf8)) else {
            return XCTFail("not unknown")
        }
        XCTAssertEqual(type, "future.frame")
        XCTAssertEqual(raw["value"]?.intValue, 1)
    }

    func testInvalidFrameThrows() {
        XCTAssertThrowsError(try ServerMessage.decode(Data("not json".utf8)))
        XCTAssertThrowsError(try ServerMessage.decode(Data(#"{"no":"type"}"#.utf8)))
    }

    func testSessionInfoDecodesWithoutV6AgentsRunning() throws {
        let json = #"{"id":"s1","title":"T","cwd":"/","project":"","model":"m","account":"a","status":"idle","mode":"default","updatedAt":"","live":false}"#
        let session = try JSONDecoder.proteus.decode(SessionInfo.self, from: Data(json.utf8))
        XCTAssertEqual(session.agentsRunning, 0)
    }

    func testProjectDefDefaultsSubagents() throws {
        let def = try JSONDecoder.proteus.decode(ProjectDef.self, from: Data(#"{"name":"P"}"#.utf8))
        XCTAssertEqual(def.subagents, [])
    }

    func testJSONValueRoundTrip() throws {
        let json = #"{"a":1,"b":1.5,"c":true,"d":null,"e":[1,"x",{"y":2}]}"#
        let value = try JSONDecoder.proteus.decode(JSONValue.self, from: Data(json.utf8))
        XCTAssertEqual(value["a"]?.intValue, 1)
        XCTAssertEqual(value["b"]?.doubleValue, 1.5)
        XCTAssertEqual(value["c"]?.boolValue, true)
        XCTAssertTrue(value["d"]?.isNull ?? false)
        XCTAssertEqual(value["e"]?.arrayValue?.count, 3)
        let reencoded = try JSONEncoder.proteus.encode(value)
        XCTAssertEqual(try JSONDecoder.proteus.decode(JSONValue.self, from: reencoded), value)
    }
}
