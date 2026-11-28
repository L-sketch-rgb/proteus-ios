import Foundation

/// A large, realistic chat history for performance checks (tests and the
/// simulator's `-ProteusDemoScreen=bigchat`): long markdown replies, tool
/// calls with 50-200 KB outputs and 20 KB diffs, sub-agent items and tasks.
public enum SyntheticHistory {
    public static func markdown(approxBytes: Int, seed: Int) -> String {
        var out = ""
        var n = 0
        while out.utf8.count < approxBytes {
            n += 1
            out += """
            ## Section \(seed).\(n) on the retry path

            The handler **retries** with `backoff(\(n))` and then calls [the docs](https://example.com/\(seed)/\(n)). \
            It keeps *every* attempt in a list, so a failure after \(n) tries reports them all, in order, with timings.

            - first item with `inline code` and **bold** text \(n)
            - second item that is a little longer so that it wraps onto a second line on a phone screen
            1. numbered \(n)
            2. numbered again

            ```swift
            func retry<T>(_ times: Int, _ work: () throws -> T) rethrows -> T {
                var last: Error?
                for attempt in 0..<times {
                    do { return try work() } catch { last = error; sleep(UInt32(attempt)) }
                }
                throw last!
            }
            ```

            | Stage | Time | Note |
            |-------|------|------|
            | decode | \(n) ms | tree |
            | fold | \(n) ms | rows |

            > A quoted remark about section \(n).


            """
        }
        return out
    }

    public static func output(approxBytes: Int, seed: Int) -> String {
        var out = ""
        var line = 0
        while out.utf8.count < approxBytes {
            line += 1
            out += "src/module\(seed % 97)/file\(line).ts:\(line):12  warning  unused variable 'value\(line)'  no-unused-vars\n"
        }
        return out
    }

    /// `count` items: transcript plus a few trailing `task` items.
    public static func items(count: Int) -> [[String: Any]] {
        var items: [[String: Any]] = []
        items.reserveCapacity(count + 8)
        var i = 0
        while items.count < count {
            let toolId = "toolu_\(i)"
            func add(_ kind: String, _ data: [String: Any]) {
                items.append(["ts": "2026-11-28T10:\(String(format: "%02d", (i / 60) % 60)):00.000Z", "kind": kind, "data": data])
            }
            switch i % 10 {
            case 0:
                add("user", ["text": "Please look at the retry handling in module \(i) and fix the flaky test."])
            case 1:
                let big = i % 20 == 1
                add("assistant", ["blocks": [
                    ["type": "text", "text": markdown(approxBytes: big ? 20_000 : 5_000, seed: i)],
                    ["type": "tool_use", "id": toolId, "name": "Bash", "input": ["command": "npm run lint\nand more"]],
                ]])
            case 2:
                let big = i % 20 == 2
                add("tool_result", ["toolUseId": "toolu_\(i - 1)", "isError": false,
                                    "text": output(approxBytes: big ? 200_000 : 50_000, seed: i)])
            case 3:
                add("assistant", ["blocks": [
                    ["type": "tool_use", "id": toolId, "name": "Edit",
                     "input": ["file_path": "/home/user/proj/src/a\(i).ts",
                               "old_string": output(approxBytes: 20_000, seed: i),
                               "new_string": output(approxBytes: 20_000, seed: i + 1)]],
                ]])
            case 4:
                add("tool_result", ["toolUseId": "toolu_\(i - 1)", "isError": false, "text": "File edited."])
            case 5:
                add("assistant", ["blocks": [
                    ["type": "tool_use", "id": toolId, "name": "Task",
                     "input": ["description": "Review module \(i)", "prompt": "Look at it."]],
                ]])
            case 6:
                add("assistant", ["parent": "toolu_\(i - 1)", "blocks": [
                    ["type": "text", "text": markdown(approxBytes: 3_000, seed: i)],
                ]])
            case 7:
                add("tool_result", ["toolUseId": "toolu_\(i - 2)", "isError": false, "text": markdown(approxBytes: 8_000, seed: i)])
            case 8:
                add("assistant", ["blocks": [
                    ["type": "text", "text": markdown(approxBytes: 12_000, seed: i)],
                ]])
            default:
                add("notice", ["text": "Background task finished"])
            }
            i += 1
        }
        for t in 0..<4 {
            items.append(["ts": "2026-11-28T11:00:0\(t).000Z", "kind": "task", "data": [
                "taskId": "task\(t)", "toolUseId": "toolu_\(t * 10 + 5)", "agent": "general-purpose",
                "description": "Review module", "status": "completed", "startedAt": "2026-11-28T10:00:00.000Z",
            ] as [String: Any]])
        }
        return items
    }

    /// The `history` frame JSON a hub would send. `offset: nil` is the old-hub
    /// shape (everything, no paging fields).
    public static func frameData(id: String, items: [[String: Any]], offset: Int?, total: Int?) throws -> Data {
        var frame: [String: Any] = ["t": "history", "id": id, "items": items, "lastSeq": 0]
        if let offset { frame["offset"] = offset }
        if let total { frame["total"] = total }
        return try JSONSerialization.data(withJSONObject: frame)
    }
}
