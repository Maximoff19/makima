import Foundation
import Testing
@testable import SwiftChat

@MainActor
struct ChecklistProtocolTests {
    private func block(_ value: String) -> String {
        ChecklistProtocol.marker + value + ChecklistProtocol.marker
    }

    @Test func observedActivityChangesWithoutBecomingAnswerOrChecklist() {
        var tail = ""
        let first = ChecklistProtocol.split(ChecklistProtocol.marker + #"{"k":"activity","s":"read"#,
                                            pending: &tail)
        #expect(first.text.isEmpty)
        let next = ChecklistProtocol.split(#"ing","detail":"agenda.py"}"# + ChecklistProtocol.marker,
                                           pending: &tail)
        let activity = AgentActivity(stage: .reading, detail: "agenda.py")
        #expect(next.payloads == [.activity(activity)])
        #expect(activity.caption == "Leyendo · agenda.py")
        #expect(ChecklistProtocol.apply(next.payloads[0], to: nil) == nil)
        #expect(ChecklistProtocol.Payload.parse(#"{"k":"activity","s":null}"#) == .activity(nil))
        #expect(ChecklistProtocol.Payload.parse(#"{"k":"activity","s":"unknown"}"#) == nil)
    }

    @Test func activityIsTransientAndDoesNotReturnFromArchives() throws {
        var message = Message(role: .assistant, content: "")
        message.agentActivity = AgentActivity(stage: .runningCommand, detail: "npm")
        let data = try JSONEncoder().encode(message)
        let restored = try JSONDecoder().decode(Message.self, from: data)
        #expect(restored.agentActivity == nil)
        #expect(restored.content.isEmpty)
    }

    @Test func activityOnlyChangesInvalidateMessageRow() async throws {
        let message = Message(role: .assistant, content: "")
        let wrapper = ObservableMessageWrapper(message: message, isDarkMode: false,
            isLastMessage: true, isLoading: true, isArchived: false, showArchiveSeparator: false)
        var updated = message
        updated.agentActivity = AgentActivity(stage: .deploying, detail: "Vercel")
        wrapper.update(message: updated, isDarkMode: false, isLastMessage: true,
            isLoading: true, isArchived: false, showArchiveSeparator: false, messageIndex: 0)
        try await Task.sleep(for: .milliseconds(50))
        #expect(wrapper.message.agentActivity?.caption == "Desplegando · Vercel")
    }

    @Test func nativeAgentTodoSnapshotOwnsTitlesAndStates() {
        var tail = ""
        let native = block(#"{"k":"todos","s":[{"content":"Build pet product catalog","status":"completed","priority":"high"},{"content":"Deploy storefront","status":"in_progress","priority":"medium"},{"content":"Add abandoned feature","status":"cancelled","priority":"low"}]}"#)
        let chunk = ChecklistProtocol.split(native, pending: &tail)
        #expect(chunk.text.isEmpty)
        let checklist = ChecklistProtocol.apply(chunk.payloads[0], to: nil)
        #expect(checklist?.steps.map(\.title) == ["Build pet product catalog", "Deploy storefront", "Add abandoned feature"])
        #expect(checklist?.steps.map(\.state) == [.done, .running, .cancelled])
        let ended = ChecklistProtocol.apply(.end, to: checklist)
        #expect(ended?.steps[1].state == .running)
    }

    @Test func everyCoalescedUpdateIsAppliedInOrder() {
        var tail = ""
        let stream = block(#"{"k":"plan","s":["Analyze","Write"]}"#)
            + block(#"{"k":"run","i":0}"#)
            + block(#"{"k":"done","i":0}"#)
            + "Final answer"
        let chunk = ChecklistProtocol.split(stream, pending: &tail)
        #expect(chunk.payloads.count == 3)
        #expect(chunk.text == "Final answer")
        #expect(tail.isEmpty)
        var checklist: ProgressChecklist?
        for payload in chunk.payloads {
            checklist = ChecklistProtocol.apply(payload, to: checklist)
        }
        #expect(checklist?.steps[0].state == .done)
        #expect(checklist?.steps[1].state == .pending)
    }

    @Test func splitBlocksNeverLeakIntoAnswerText() {
        var tail = ""
        let first = ChecklistProtocol.split("Before" + ChecklistProtocol.marker + #"{"k":"pl"#, pending: &tail)
        #expect(first.text == "Before")
        #expect(first.payloads.isEmpty)
        let next = ChecklistProtocol.split(#"an","s":["Analyze"]}"# + ChecklistProtocol.marker + "After", pending: &tail)
        #expect(next.text == "After")
        #expect(next.payloads == [.plan(["Analyze"])])
        #expect(tail.isEmpty)
    }

    @Test func endNeverFabricatesSuccessfulSteps() {
        var checklist = ChecklistProtocol.apply(.plan(["Analyze", "Deploy"]), to: nil)
        checklist = ChecklistProtocol.apply(.failed(1), to: checklist)
        checklist = ChecklistProtocol.apply(.end, to: checklist)
        #expect(checklist?.isFinished == true)
        #expect(checklist?.steps[0].state == .pending)
        #expect(checklist?.steps[1].state == .failed)
    }

    @Test func checklistSurvivesSavingAndReloadingChat() throws {
        let checklist = ProgressChecklist(steps: [ProgressStep(id: 0, title: "Analyze", state: .done)])
        let message = Message(role: .assistant, content: "Done", checklist: checklist)
        let data = try JSONEncoder().encode(message)
        let restored = try JSONDecoder().decode(Message.self, from: data)
        #expect(restored.checklist == checklist)
        // Old messages with no checklist key remain readable.
        let old = try JSONDecoder().decode(Message.self, from: Data(#"{"role":"assistant","content":"Hello"}"#.utf8))
        #expect(old.checklist == nil)
    }

    @Test func checklistOnlyChangesInvalidateMessageRow() async throws {
        let checklist = ProgressChecklist(steps: [ProgressStep(id: 0, title: "Analyze")])
        let message = Message(role: .assistant, content: "", checklist: checklist)
        let wrapper = ObservableMessageWrapper(message: message, isDarkMode: false,
            isLastMessage: true, isLoading: true, isArchived: false, showArchiveSeparator: false)
        var updated = message
        updated.checklist?.steps[0].state = .done
        wrapper.update(message: updated, isDarkMode: false, isLastMessage: true,
            isLoading: true, isArchived: false, showArchiveSeparator: false, messageIndex: 0)
        // The wrapper deliberately publishes on the next main run-loop iteration.
        try await Task.sleep(for: .milliseconds(50))
        #expect(wrapper.message.checklist?.steps[0].state == .done)
        #expect(wrapper.message.content.isEmpty)
    }
}
