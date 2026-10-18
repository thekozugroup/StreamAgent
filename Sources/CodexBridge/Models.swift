import Foundation

public enum AgentStatus: String, Codable, CaseIterable {
    case working, thinking, waiting, done, idle, unknown, failed

    public var label: String { rawValue.capitalized }

    public var symbol: String {
        switch self {
        case .working: return "gearshape.2.fill"
        case .thinking: return "brain"
        case .waiting: return "hand.raised.fill"
        case .done: return "checkmark.circle.fill"
        case .idle: return "pause.circle"
        case .unknown: return "questionmark.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

public struct AgentSession: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let displayName: String
    public let projectPath: String
    public let projectName: String
    public let status: AgentStatus
    public let updatedAt: Date
    public let statusDetail: String

    public var deepLink: URL? {
        guard !id.isEmpty, id.utf8.count <= 256,
              id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }) else { return nil }
        var parts = URLComponents()
        parts.scheme = "codex"
        parts.host = "threads"
        parts.path = "/" + id
        return parts.url
    }

    public init(id: String, title: String, projectPath: String, projectName: String,
                status: AgentStatus, updatedAt: Date, statusDetail: String, displayName: String? = nil) {
        self.id = id
        self.title = title
        self.displayName = displayName.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? title
        self.projectPath = projectPath
        self.projectName = projectName
        self.status = status
        self.updatedAt = updatedAt
        self.statusDetail = statusDetail
    }
}

public struct AgentProject: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let path: String
    public let sessions: [AgentSession]

    public init(id: String, name: String, path: String, sessions: [AgentSession]) {
        self.id = id
        self.name = name
        self.path = path
        self.sessions = sessions
    }
}

struct StatusEvidence {
    let status: AgentStatus
    let detail: String

    static let unavailable = StatusEvidence(status: .unknown, detail: "No readable status evidence")

    static func running(at date: Date?, now: Date, reasoning: Bool = false) -> StatusEvidence {
        guard let date = date, now.timeIntervalSince(date) >= -30,
              now.timeIntervalSince(date) <= 120 else {
            return StatusEvidence(status: .unknown, detail: "Running evidence is stale or has no valid timestamp")
        }
        return StatusEvidence(status: reasoning ? .thinking : .working,
                              detail: reasoning ? "Open reasoning item in a running turn" : "Running turn with recent durable evidence")
    }
}
