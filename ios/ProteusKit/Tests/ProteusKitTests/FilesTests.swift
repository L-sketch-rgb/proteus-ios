import XCTest
@testable import ProteusKit

/// v13 §2.1 / v17: workstation roots, search and the fs.mkdir/rename/delete
/// writes.
final class FilesTests: XCTestCase {
    private func object(_ frame: ClientFrame) throws -> JSONValue {
        try JSONDecoder.proteus.decode(JSONValue.self, from: frame.encoded())
    }

    func testRootScopedListAndRead() throws {
        let list = try object(.fsList(root: "home", path: "/home/user", rid: "r1"))
        XCTAssertEqual(list["t"]?.stringValue, "fs.list")
        XCTAssertEqual(list["root"]?.stringValue, "home")
        XCTAssertNil(list["id"])

        let read = try object(.fsRead(root: "home", path: "/home/user/a.txt", maxBytes: 100))
        XCTAssertEqual(read["root"]?.stringValue, "home")
        XCTAssertEqual(read["maxBytes"]?.intValue, 100)

        let chat = try object(FsScope.chat("s1").list(path: "/w"))
        XCTAssertEqual(chat["id"]?.stringValue, "s1")
        let rooted = try object(FsScope.root("home").read(path: "/w/a"))
        XCTAssertEqual(rooted["root"]?.stringValue, "home")
    }

    func testWriteAndSearchFrames() throws {
        let mk = try object(.fsMkdir(root: "home", path: "/home/user/new", rid: "m"))
        XCTAssertEqual(mk["t"]?.stringValue, "fs.mkdir")
        XCTAssertEqual(mk["path"]?.stringValue, "/home/user/new")

        let rn = try object(.fsRename(root: "home", path: "/home/user/a", name: "b"))
        XCTAssertEqual(rn["t"]?.stringValue, "fs.rename")
        XCTAssertEqual(rn["name"]?.stringValue, "b")

        let rm = try object(.fsDelete(root: "home", path: "/home/user/a"))
        XCTAssertEqual(rm["t"]?.stringValue, "fs.delete")

        let find = try object(.fsFind(root: "computer", query: "log", limit: 50, path: "/var"))
        XCTAssertEqual(find["t"]?.stringValue, "fs.find")
        XCTAssertEqual(find["limit"]?.intValue, 50)
        XCTAssertEqual(find["path"]?.stringValue, "/var")
        let everywhere = try object(.fsFind(root: "computer", query: "log"))
        XCTAssertNil(everywhere["path"])
        XCTAssertNil(everywhere["limit"])

        XCTAssertEqual(try object(.fsRoots())["t"]?.stringValue, "fs.roots")
    }

    func testDecodeRootsFoundAndDone() throws {
        let roots = """
        {"t":"fs.roots","rid":"r","roots":[
          {"id":"home","label":"Home","path":"/home/user","group":"places","icon":"home"},
          {"id":"computer","label":"Computer","path":"/","group":"devices","icon":"computer","free":10,"total":100}]}
        """
        guard case .fsRoots(let frame) = try ServerMessage.decode(Data(roots.utf8)) else {
            return XCTFail("expected fs.roots")
        }
        XCTAssertEqual(frame.roots.count, 2)
        XCTAssertEqual(frame.roots[1].free, 10)
        XCTAssertEqual(FsPaths.grouped(frame.roots).map(\.group), ["places", "devices"])
        XCTAssertEqual(FsPaths.root(containing: "/home/user/x/y", in: frame.roots)?.id, "home")
        XCTAssertEqual(FsPaths.root(containing: "/etc/hosts", in: frame.roots)?.id, "computer")

        let found = """
        {"t":"fs.found","rid":"f","root":"home","truncated":true,"entries":[
          {"name":"a.log","dir":false,"size":3,"mtime":"2026-11-09T08:00:00Z","path":"/home/user/a.log"},
          {"name":"logs","dir":true,"count":4,"path":"/home/user/logs"}]}
        """
        guard case .fsFound(let hits) = try ServerMessage.decode(Data(found.utf8)) else {
            return XCTFail("expected fs.found")
        }
        XCTAssertTrue(hits.truncated)
        XCTAssertEqual(hits.entries[0].path, "/home/user/a.log")
        XCTAssertEqual(hits.entries[1].count, 4)

        let done = #"{"t":"fs.done","rid":"m","op":"rename","root":"home","path":"/home/user/b"}"#
        guard case .fsDone(let result) = try ServerMessage.decode(Data(done.utf8)) else {
            return XCTFail("expected fs.done")
        }
        XCTAssertEqual(result, FsDoneFrame(rid: "m", op: "rename", root: "home", path: "/home/user/b"))
    }

    func testPathHelpers() {
        XCTAssertEqual(FsPaths.parent(of: "/home/user/a"), "/home/user")
        XCTAssertEqual(FsPaths.parent(of: "/home/"), "/")
        XCTAssertEqual(FsPaths.parent(of: "/a"), "/")
        XCTAssertEqual(FsPaths.join("/", "etc"), "/etc")
        XCTAssertEqual(FsPaths.join("/a", "b"), "/a/b")
    }
}
