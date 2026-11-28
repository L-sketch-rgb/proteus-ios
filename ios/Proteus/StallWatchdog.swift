import Foundation

/// Measures how long the main thread is unresponsive. A background thread
/// posts a block to the main queue every 50 ms and times how long it takes to
/// run; the largest delay is the longest stall. Used by the
/// `-ProteusDemoScreen=bigchat` route, which CI launches on the simulator and
/// fails when the number is over budget. Nothing here runs in normal use.
final class StallWatchdog {
    static let shared = StallWatchdog()

    private let lock = NSLock()
    private var maxMs = 0
    private var currentPhase = "idle"
    private var lines: [String] = []
    private var perPhase: [String: Int] = [:]
    private var startedAt: UInt64?

    /// Notes a milestone with the time since the watchdog started. A no-op
    /// outside the demo.
    func mark(_ name: String) {
        lock.lock()
        let started = startedAt
        lock.unlock()
        guard let started else { return }
        let ms = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        note("\(name) at +\(ms) ms")
    }

    /// What the demo is doing now, so a stall is attributed to a stage.
    var phase: String {
        get { lock.lock(); defer { lock.unlock() }; return currentPhase }
        set { lock.lock(); currentPhase = newValue; lock.unlock() }
    }

    func note(_ text: String) {
        lock.lock()
        lines.append(text)
        lock.unlock()
        NSLog("STALL_NOTE \(text)")
    }

    func start(seconds: Double) {
        lock.lock()
        startedAt = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
        let thread = Thread { [self] in
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                let semaphore = DispatchSemaphore(value: 0)
                let sent = DispatchTime.now().uptimeNanoseconds
                let phaseAtSend = phase
                DispatchQueue.main.async { semaphore.signal() }
                semaphore.wait()
                let ms = Int((DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000)
                lock.lock()
                if ms > maxMs { maxMs = ms }
                if ms > (perPhase[phaseAtSend] ?? 0) { perPhase[phaseAtSend] = ms }
                if ms >= 100 { lines.append("stall \(ms) ms during \(phaseAtSend) (now \(currentPhase))") }
                lock.unlock()
                Thread.sleep(forTimeInterval: 0.05)
            }
            finish()
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func finish() {
        lock.lock()
        let phases = perPhase.sorted { $0.key < $1.key }.map { "max stall in \($0.key): \($0.value) ms" }
        let report = (lines + phases).joined(separator: "\n") + "\nMAX_MAIN_STALL_MS=\(maxMs)\n"
        lock.unlock()
        print(report)
        NSLog("MAX_MAIN_STALL_MS=\(maxMs)")
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? report.write(to: documents.appendingPathComponent("stall.txt"), atomically: true, encoding: .utf8)
        }
    }
}
