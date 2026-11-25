import Foundation

/// All sub-agent tasks of one chat (v6). Each `task` event carries the full
/// state, so rows are replaced, never merged.
public final class TaskStore {
    public private(set) var tasks: [String: TaskData] = [:]
    public var onChange: (() -> Void)?

    public init() {}

    public func reset() {
        tasks = [:]
        onChange?()
    }

    public func replace(_ task: TaskData) {
        tasks[task.taskId] = task
        onChange?()
    }

    public func replaceAll(_ tasks: [TaskData]) {
        self.tasks = Dictionary(uniqueKeysWithValues: tasks.map { ($0.taskId, $0) })
        onChange?()
    }

    public func remove(taskId: String) {
        tasks.removeValue(forKey: taskId)
        onChange?()
    }

    public var runningCount: Int {
        tasks.values.filter(\.isRunning).count
    }

    /// Everything that is no longer running (completed, failed or stopped).
    public var finishedCount: Int {
        tasks.values.filter { !$0.isRunning }.count
    }

    public var totalTokens: Int {
        tasks.values.compactMap(\.tokens).reduce(0, +)
    }

    public var totalDurationMs: Int {
        tasks.values.compactMap(\.durationMs).reduce(0, +)
    }

    /// Running first (newest start first), then finished (newest start first).
    public var sorted: [TaskData] {
        tasks.values.sorted { lhs, rhs in
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            let l = Formatting.parseISO(lhs.startedAt) ?? .distantPast
            let r = Formatting.parseISO(rhs.startedAt) ?? .distantPast
            if l != r { return l > r }
            return lhs.taskId < rhs.taskId
        }
    }

    /// v9 §4: the running agents, in the panel's order.
    public var running: [TaskData] {
        sorted.filter(\.isRunning)
    }

    /// v9 §4: completed, failed and stopped agents for the "Finished (n)"
    /// group, still newest start first.
    public var finished: [TaskData] {
        sorted.filter { !$0.isRunning }
    }

    public func task(taskId: String) -> TaskData? {
        tasks[taskId]
    }

    public func task(toolUseId: String) -> TaskData? {
        tasks.values.first { $0.toolUseId == toolUseId }
    }

    /// "2 running · 5 done · 184k tokens · 12:40 total"
    public func summaryLine() -> String {
        let tokens = Formatting.tokens(totalTokens)
        let duration = Formatting.duration(milliseconds: totalDurationMs)
        return "\(runningCount) running · \(finishedCount) done · \(tokens) tokens · \(duration) total"
    }

    public func liveDurationMs(for task: TaskData, now: Date = Date()) -> Int? {
        if task.isRunning, let elapsed = Formatting.elapsedSeconds(sinceISO: task.startedAt, now: now) {
            return elapsed * 1000
        }
        return task.durationMs
    }
}
