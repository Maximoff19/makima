import Foundation

/// Transient, observed agent activity. Never save it as conversation content or replay it.
struct AgentActivity: Equatable, Sendable {
    enum Stage: String, Sendable {
        case waiting, thinking, composing, reading, editing, searching
        case loadingSkill = "loading_skill"
        case runningCommand = "running_command"
        case deploying, testing, planning, memory, working
    }

    let stage: Stage
    let detail: String

    var caption: String {
        let label: String
        switch stage {
        case .waiting: label = "Esperando respuesta"
        case .thinking: label = "Pensando"
        case .composing: label = "Redactando"
        case .reading: label = "Leyendo"
        case .editing: label = "Editando"
        case .searching: label = "Buscando"
        case .loadingSkill: label = "Cargando skill"
        case .runningCommand: label = "Ejecutando comando"
        case .deploying: label = "Desplegando"
        case .testing: label = "Ejecutando pruebas"
        case .planning: label = "Actualizando el plan"
        case .memory: label = "Consultando memoria"
        case .working: label = "Trabajando"
        }
        return detail.isEmpty ? label : "\(label) · \(detail)"
    }
}
