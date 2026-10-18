import CodexBridge
import Foundation

// Privacy-safe by construction: never serialize AgentProject/AgentSession.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.allSatisfy({ $0 == "--json" }) else {
    FileHandle.standardError.write(Data("Usage: CodexProbe [--json]\n".utf8))
    exit(2)
}
let monitor = CodexMonitor()
let began = Date()
monitor.refresh()
while monitor.lastRefresh == nil && Date().timeIntervalSince(began) < 8 {
    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
}
guard monitor.lastRefresh != nil else {
    FileHandle.standardError.write(Data("Codex metadata scan timed out\n".utf8))
    exit(1)
}
let sessions = monitor.projects.flatMap(\.sessions)
let namedThreadCount = sessions.filter { $0.displayName != $0.title }.count
let counts = Dictionary(uniqueKeysWithValues: AgentStatus.allCases.map { status in
    (status.rawValue, sessions.filter { $0.status == status }.count)
})
if arguments.contains("--json") {
    let output: [String: Any] = [
        "projectCount": monitor.projects.count,
        "threadCount": sessions.count,
        "namedThreadCount": namedThreadCount,
        "statuses": counts,
        "diagnosticSource": monitor.statusMessage,
        "scanMilliseconds": Int(Date().timeIntervalSince(began) * 1000)
    ]
    let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} else {
    print("Projects: \(monitor.projects.count); threads: \(sessions.count)")
    print("Distinct name labels: \(namedThreadCount)")
    print(AgentStatus.allCases.map { "\($0.label): \(counts[$0.rawValue] ?? 0)" }.joined(separator: "; "))
    print("Sources: \(monitor.statusMessage)")
}
monitor.stop()
