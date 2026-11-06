import SwiftUI

/// Live progress checklist for a Super Makima implementation task.
///
/// A completed step is a red circle with a white check inside it, as specified. Pending steps
/// stay hollow. The list re-renders as each tick arrives, so the user watches the work advance
/// instead of staring at a frozen chat.
struct ChecklistView: View {
    let checklist: ProgressChecklist
    var isDarkMode: Bool = false
    var isStreaming: Bool = false

    private let circleSize: CGFloat = 18
    private let pendingColor: Color

    init(checklist: ProgressChecklist, isDarkMode: Bool = false, isStreaming: Bool = false) {
        self.checklist = checklist
        self.isDarkMode = isDarkMode
        self.isStreaming = isStreaming
        self.pendingColor = isDarkMode ? Color.white.opacity(0.35) : Color.primary.opacity(0.3)
    }

    var body: some View {
        if !checklist.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(checklist.steps) { step in
                    row(step)
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
        }
    }

    @ViewBuilder
    private func row(_ step: ProgressStep) -> some View {
        HStack(spacing: 10) {
            marker(for: step)
                .frame(width: circleSize, height: circleSize)

            Text(step.title)
                .font(.subheadline)
                .foregroundStyle(step.state == .done ? Color.primary : pendingColor)

            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.2), value: step.state)
    }

    /// Red disc with a white check once done; hollow circle while pending or running.
    @ViewBuilder
    private func marker(for step: ProgressStep) -> some View {
        let state = step.state
        switch state {
        case .done:
            ZStack {
                Circle()
                    .fill(Color.red)
                Image(systemName: "checkmark")
                    .font(.system(size: circleSize * 0.52, weight: .black))
                    .foregroundStyle(.white)
            }
        case .pending, .running:
            ZStack {
                Circle()
                    .strokeBorder(pendingColor, lineWidth: 1.5)
                if state == .running && isStreaming {
                    Circle()
                        .fill(pendingColor)
                        .frame(width: circleSize * 0.3, height: circleSize * 0.3)
                }
            }
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle")
                .foregroundStyle(pendingColor)
        }
    }

    private var accessibilityText: String {
        let done = checklist.completedCount
        let total = checklist.steps.count
        return "Progress: \(done) of \(total) steps completed. "
            + checklist.steps.map { "\($0.title): \($0.state.rawValue)" }
                .joined(separator: ", ")
    }
}

#Preview("Checklist") {
    VStack(alignment: .leading, spacing: 16) {
        ChecklistView(
            checklist: ProgressChecklist(steps: [
                ProgressStep(id: 0, title: "Analizando el proyecto", state: .done),
                ProgressStep(id: 1, title: "Modificando los archivos", state: .done),
                ProgressStep(id: 2, title: "Ejecutando la implementación"),
                ProgressStep(id: 3, title: "Verificando los cambios"),
            ]),
            isStreaming: true
        )
        ChecklistView(
            checklist: ProgressChecklist(
                steps: (0..<4).map {
                    ProgressStep(id: $0, title: "Paso \($0 + 1)", state: .done)
                },
                isFinished: true
            )
        )
    }
    .padding()
}
