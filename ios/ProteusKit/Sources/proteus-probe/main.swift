import Foundation
import ProteusKit

// Read-only connection check: hello -> welcome -> counts -> exit.
// Usage: PROTEUS_TOKEN=... proteus-probe <host> <port>
// The token is only read from the environment and is never printed.

let arguments = CommandLine.arguments
guard arguments.count >= 3, let port = Int(arguments[2]) else {
    FileHandle.standardError.write(Data("usage: PROTEUS_TOKEN=... proteus-probe <host> <port>\n".utf8))
    exit(2)
}
guard let token = ProcessInfo.processInfo.environment["PROTEUS_TOKEN"], !token.isEmpty else {
    FileHandle.standardError.write(Data("PROTEUS_TOKEN is not set\n".utf8))
    exit(2)
}

let configuration = HubConfiguration(
    host: arguments[1],
    port: port,
    token: token,
    name: "probe",
    client: "test",
    version: 1
)

let done = DispatchSemaphore(value: 0)
var failure: String?
var counts: (sessions: Int, models: Int, accounts: Int, projects: Int)?

let client = HubClient(
    configuration: configuration,
    queue: nil,
    callbackQueue: nil,
    pingInterval: 60,
    backoff: [1]
)
client.onWelcome = { welcome in
    counts = (
        welcome.sessions.count,
        welcome.models.count,
        welcome.accounts.count,
        welcome.projectDefs.count
    )
    done.signal()
}
client.onMessage = { message in
    if case .err(let error) = message {
        failure = "hub error: \(error.code)"
        done.signal()
    }
}
client.onError = { message in
    if failure == nil, counts == nil {
        failure = message
        done.signal()
    }
}
client.connect()

if done.wait(timeout: .now() + 15) == .timedOut {
    FileHandle.standardError.write(Data("timed out waiting for welcome\n".utf8))
    exit(3)
}
if let failure {
    FileHandle.standardError.write(Data("probe failed: \(failure)\n".utf8))
    exit(4)
}
guard let counts else {
    FileHandle.standardError.write(Data("no welcome received\n".utf8))
    exit(4)
}

print("sessions: \(counts.sessions)")
print("models: \(counts.models)")
print("accounts: \(counts.accounts)")
print("projects: \(counts.projects)")
client.disconnect()
exit(0)
