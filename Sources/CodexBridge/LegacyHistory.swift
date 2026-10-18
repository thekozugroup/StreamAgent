import Foundation

struct LegacySignal {
    var status: AgentStatus = .unknown
    var timestamp: Date?
    var running = false
    var requestIDs: Set<String> = []
    var anonymousRequest = false

    func evidence(now: Date) -> StatusEvidence {
        switch status {
        case .working, .thinking:
            return StatusEvidence.running(at: timestamp, now: now, reasoning: status == .thinking)
        case .waiting:
            return StatusEvidence(status: .waiting, detail: "Explicit unresolved approval or user-input request in legacy events")
        case .done: return StatusEvidence(status: .done, detail: "Latest legacy turn completed")
        case .idle: return StatusEvidence(status: .idle, detail: "Latest legacy turn interrupted")
        case .failed: return StatusEvidence(status: .failed, detail: "Latest legacy turn failed")
        case .unknown: return .unavailable
        }
    }
}

enum LegacyHistory {
    static func read(url: URL, deadline: Date) -> LegacySignal {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return LegacySignal() }
        guard let file = try? FileHandle(forReadingFrom: url) else { return LegacySignal() }
        defer { try? file.close() }
        do {
            let length = try file.seekToEnd()
            let start = length > 262_144 ? length - 262_144 : 0
            try file.seek(toOffset: start)
            var data = try file.read(upToCount: 262_144) ?? Data()
            if start > 0 {
                guard let newline = data.firstIndex(of: 10) else { return LegacySignal() }
                data = data.subdata(in: data.index(after: newline)..<data.endIndex)
            }
            var signal = LegacySignal()
            let decoder = JSONDecoder()
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            var lines = 0
            for line in data.split(separator: 10, omittingEmptySubsequences: true) {
                lines += 1
                guard lines <= 2048, lines % 32 != 1 || Date() < deadline else { return LegacySignal() }
                guard let record = try? decoder.decode(LegacyRecord.self, from: Data(line)) else {
                    // A truncated/corrupt record may contain a missing completion/resolution.
                    signal = LegacySignal()
                    continue
                }
                let timestamp = record.timestamp.flatMap { fractional.date(from: $0) ?? plain.date(from: $0) }
                consume(record, timestamp: timestamp, into: &signal)
            }
            return signal
        } catch { return LegacySignal() }
    }

    private static func consume(_ record: LegacyRecord, timestamp date: Date?, into signal: inout LegacySignal) {
        let payload = record.payload
        let type = record.method ?? payload?.method ?? payload?.type ?? record.type ?? ""
        let requestID = payload?.requestID?.value ?? payload?.callID?.value ?? record.params?.requestID?.value ?? record.id?.value
        let blocking = payload?.isBlocking ?? record.params?.isBlocking
        func set(_ status: AgentStatus, running: Bool) {
            signal = LegacySignal(status: status, timestamp: date, running: running)
        }
        switch type {
        case "task_started", "turn_started", "turn/started":
            set(.working, running: true)
        case "task_complete", "task_completed", "turn_completed", "turn/completed":
            let terminal = record.params?.turn?.status ?? payload?.status
            if terminal == "failed" { set(.failed, running: false) }
            else if terminal == "interrupted" { set(.idle, running: false) }
            else if terminal == nil || terminal == "completed" { set(.done, running: false) }
            else { set(.unknown, running: false) }
        case "turn_aborted", "turn_interrupted", "task_interrupted":
            set(.idle, running: false)
        case "task_failed", "turn_failed":
            set(.failed, running: false)
        case "exec_approval_request", "apply_patch_approval_request", "request_user_input",
             "item/commandExecution/requestApproval", "item/fileChange/requestApproval",
             "item/permissions/requestApproval", "item/tool/requestUserInput":
            if blocking != false {
                signal.status = .waiting
                signal.running = true
                signal.timestamp = date
                if let requestID = requestID { signal.requestIDs.insert(requestID) }
                else { signal.anonymousRequest = true }
            }
        case "exec_approval_response", "apply_patch_approval_response", "request_user_input_response",
             "approval_resolved", "user_input_response", "serverRequest/resolved":
            if signal.status == .waiting {
                if let requestID = requestID { signal.requestIDs.remove(requestID) }
                else { signal.anonymousRequest = false }
                if signal.requestIDs.isEmpty && !signal.anonymousRequest { set(.working, running: true) }
            }
        case "agent_reasoning_delta", "agent_reasoning_raw_content_delta", "agent_reasoning_section_break":
            if signal.running && signal.status != .waiting { set(.thinking, running: true) }
        case "item/started", "item/completed":
            if signal.running && signal.status != .waiting {
                set(type == "item/started" && record.params?.item?.type == "reasoning" ? .thinking : .working, running: true)
            }
        case "exec_command_begin", "exec_command_end", "mcp_tool_call_begin", "mcp_tool_call_end",
             "apply_patch_begin", "apply_patch_end", "agent_message_delta":
            if signal.running && signal.status != .waiting { set(.working, running: true) }
        default:
            // A response item is a completed artifact, not a live reasoning/terminal signal.
            if record.type == "response_item", signal.running && signal.status != .waiting {
                set(.working, running: true)
            }
        }
    }

}

// Decode only status metadata. No prompt/content/text/arguments/output fields are modeled or retained.
private struct LegacyRecord: Decodable {
    let id: MetadataID?
    let timestamp: String?
    let type: String?
    let method: String?
    let payload: LegacyPayload?
    let params: LegacyParams?
}

private struct LegacyPayload: Decodable {
    let type: String?
    let method: String?
    let status: String?
    let requestID: MetadataID?
    let callID: MetadataID?
    let isBlocking: Bool?

    enum CodingKeys: String, CodingKey {
        case type, method, status
        case requestID = "request_id", callID = "call_id", isBlocking = "is_blocking"
    }
}

private struct LegacyParams: Decodable {
    let requestID: MetadataID?
    let isBlocking: Bool?
    let turn: LegacyTurn?
    let item: LegacyItem?

    enum CodingKeys: String, CodingKey {
        case requestID = "requestId", isBlocking, turn, item
    }
}

private struct LegacyTurn: Decodable { let status: String? }
private struct LegacyItem: Decodable { let type: String? }

private struct MetadataID: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) { value = text }
        else { value = String(try container.decode(Int64.self)) }
    }
}
