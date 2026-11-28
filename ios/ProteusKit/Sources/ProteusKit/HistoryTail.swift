import Foundation

/// A hub that predates paging answers `session.open` with the whole history
/// (thousands of items for a long chat). The app only folds and shows the
/// newest few, keeps the rest as a backlog, and pages it in locally, so
/// opening a chat costs the same on either hub.
public enum HistoryTail {
    /// Rows folded for the first screen.
    public static let initialKeep = 16

    /// At most this many older items stay in memory as a backlog. A phone
    /// holds a bounded window of a chat, not a 4000-item transcript.
    public static let maxHeld = 600

    /// A held item keeps its text but not its megabytes: tool output and
    /// tool-input strings are cut hard, other strings are left alone.
    static func compact(_ item: HistoryItem) -> HistoryItem {
        switch item.kind {
        case "tool_result":
            guard let text = item.data["text"]?.stringValue, text.utf8.count > 2_000,
                  case .object(var object) = item.data else { return item }
            object["text"] = .string(String(text.prefix(2_000)))
            return HistoryItem(ts: item.ts, kind: item.kind, data: .object(object))
        case "assistant":
            guard case .object(var object) = item.data, let blocks = object["blocks"]?.arrayValue else { return item }
            object["blocks"] = .array(blocks.map { (block: JSONValue) -> JSONValue in
                guard block["type"]?.stringValue == "tool_use", case .object(var b) = block,
                      let input = b["input"] else { return block }
                b["input"] = input.cappingStrings(1_000)
                return .object(b)
            })
            return HistoryItem(ts: item.ts, kind: item.kind, data: .object(object))
        default:
            return item
        }
    }

    /// Splits a full history into (older backlog, newest tail). `task` items
    /// always stay in the tail: they are live state, not transcript, and the
    /// Agents list needs all of them. Paged hubs (`offset != nil`) are already
    /// small and pass through untouched.
    public static func split(
        _ items: [HistoryItem],
        offset: Int?,
        keep: Int = initialKeep
    ) -> (held: [HistoryItem], tail: [HistoryItem]) {
        guard offset == nil else { return ([], items) }
        let chatCount = items.reduce(0) { $0 + ($1.kind == "task" ? 0 : 1) }
        guard chatCount > keep else { return ([], items) }
        var toHold = chatCount - keep
        var held: [HistoryItem] = []
        var tail: [HistoryItem] = []
        held.reserveCapacity(min(toHold, maxHeld))
        tail.reserveCapacity(keep + 8)
        // Only the newest `maxHeld` of the older items are kept (compacted).
        var skip = max(0, toHold - maxHeld)
        for item in items {
            if item.kind == "task" {
                tail.append(item)
            } else if toHold > 0 {
                toHold -= 1
                if skip > 0 {
                    skip -= 1
                } else {
                    held.append(compact(item))
                }
            } else {
                tail.append(item)
            }
        }
        return (held, tail)
    }
}
