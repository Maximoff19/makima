import Foundation

/// Parses the progress-checklist control blocks the Super Makima gateway rides inside the
/// ordinary text stream.
///
/// The Responses API has no checklist event, and the client folds every text delta into one
/// message string it can never rewrite. So the gateway wraps each tick in a record-separator
/// delimited JSON block; anything outside those markers is ordinary answer text and passes
/// straight through.
///
/// Streaming can split a block across two deltas, so the parser is stateful: it holds an
/// unterminated tail until the rest of it arrives.
enum ChecklistProtocol {

    static let marker = "\u{001E}"

    struct AgentTodo: Decodable, Equatable {
        let content: String
        let status: String
        let priority: String
    }

    enum Payload: Equatable {
        case activity(AgentActivity?)
        case todos([AgentTodo])
        case plan([String])
        case run(Int)
        case done(Int)
        case failed(Int)
        case end

        /// Decoded with JSONSerialization rather than Codable: an initializer cannot return a
        /// value, and an unknown or malformed block must yield nil instead of throwing.
        static func parse(_ json: String) -> Payload? {
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let kind = object["k"] as? String
            else { return nil }
            switch kind {
            case "activity":
                if object["s"] is NSNull { return .activity(nil) }
                guard let raw = object["s"] as? String,
                      let stage = AgentActivity.Stage(rawValue: raw) else { return nil }
                let detail = (object["detail"] as? String ?? "")
                    .components(separatedBy: .controlCharacters).joined()
                return .activity(AgentActivity(stage: stage, detail: String(detail.prefix(80))))
            case "todos":
                guard let list = object["s"],
                      let data = try? JSONSerialization.data(withJSONObject: list),
                      let todos = try? JSONDecoder().decode([AgentTodo].self, from: data) else { return nil }
                return .todos(todos)
            case "plan":
                guard let steps = object["s"] as? [String] else { return nil }
                return .plan(steps)
            case "done":
                guard let index = object["i"] as? Int else { return nil }
                return .done(index)
            case "run":
                guard let index = object["i"] as? Int else { return nil }
                return .run(index)
            case "failed":
                guard let index = object["i"] as? Int else { return nil }
                return .failed(index)
            case "end":
                return .end
            default:
                return nil
            }
        }
    }

    struct Chunk {
        var text: String
        var payloads: [Payload]
    }

    /// Preserve every control block, including several coalesced into one network chunk.
    static func split(_ incoming: String, pending: inout String) -> Chunk {
        var buffer = pending + incoming
        pending = ""

        var text = ""
        var payloads: [Payload] = []

        while let start = buffer.range(of: marker) {
            text += String(buffer[buffer.startIndex..<start.lowerBound])
            guard let end = buffer.range(of: marker, range: start.upperBound..<buffer.endIndex) else {
                // Block is still arriving. Keep the fragment for the next delta.
                pending = String(buffer[start.lowerBound...])
                return Chunk(text: text, payloads: payloads)
            }
            let json = String(buffer[start.upperBound..<end.lowerBound])
            if let payload = Payload.parse(json) { payloads.append(payload) }
            buffer = String(buffer[end.upperBound...])
        }

        text += buffer
        return Chunk(text: text, payloads: payloads)
    }

    /// Apply a control payload to a checklist, returning the new state.
    static func apply(_ payload: Payload, to current: ProgressChecklist?) -> ProgressChecklist? {
        switch payload {
        case .activity:
            return current
        case .todos(let todos):
            guard !todos.isEmpty else { return nil }
            return ProgressChecklist(steps: todos.enumerated().map { index, todo in
                let state: ProgressStepState
                switch todo.status {
                case "completed": state = .done
                case "in_progress": state = .running
                case "cancelled": state = .cancelled
                default: state = .pending
                }
                return ProgressStep(id: index, title: todo.content, state: state)
            })
        case .plan(let titles):
            return ProgressChecklist(steps: titles.enumerated().map {
                ProgressStep(id: $0.offset, title: $0.element, state: .pending)
            })
        case .done(let index):
            guard var checklist = current, checklist.steps.indices.contains(index) else { return current }
            checklist.steps[index].state = .done
            return checklist
        case .run(let index):
            guard var checklist = current, checklist.steps.indices.contains(index) else { return current }
            checklist.steps[index].state = .running
            return checklist
        case .failed(let index):
            guard var checklist = current, checklist.steps.indices.contains(index) else { return current }
            checklist.steps[index].state = .failed
            return checklist
        case .end:
            guard var checklist = current else { return current }
            checklist.isFinished = true
            // End is not evidence of success. Pending/failed steps must not turn into checks.
            return checklist
        }
    }
}
