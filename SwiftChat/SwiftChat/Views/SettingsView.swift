import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = SettingsManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                appearanceSection
                voiceSection
                behaviourSection
                aboutSection
            }
            .softTopEdge()
            .foregroundStyle(.white)
            .navigationTitle("Configuración")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Color(hex: "000000"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
        }
        .tint(SettingsManager.shared.accentColor)
        .preferredColorScheme(.dark)
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        Section {
            Toggle("Fondo totalmente negro", isOn: $settings.pureBlackBackground)
            Toggle("Texto junto al orbe", isOn: $settings.orbCaptionsEnabled)

            VStack(alignment: .leading, spacing: 10) {
                Text("Color principal")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                    ForEach(SettingsManager.accentPresets, id: \.hex) { preset in
                        Button {
                            settings.accentHex = preset.hex
                        } label: {
                            Circle()
                                .fill(Color(hex: preset.hex))
                                .frame(width: 30, height: 30)
                                .overlay {
                                    if settings.accentHex == preset.hex {
                                        Circle().stroke(.white, lineWidth: 2)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(preset.name)
                    }
                }
            }
        } header: {
            Text("Apariencia")
        }
    }

    // MARK: Voice

    private var voiceSection: some View {
        Section {
            Toggle("Modo de voz", isOn: $settings.voiceModeEnabled)
            Toggle("Reproducir respuestas en voz", isOn: $settings.autoPlayResponses)
            Toggle("Silenciar", isOn: $settings.isMuted)
            VStack(alignment: .leading) {
                Text("Velocidad de la voz")
                Slider(value: $settings.speechSpeed, in: 0.7...1.4, step: 0.05) {
                    Text("Velocidad")
                } minimumValueLabel: {
                    Text("Lenta")
                } maximumValueLabel: {
                    Text("Rápida")
                }
                Text(String(format: "%.2f×", settings.speechSpeed))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Voz")
        }
    }

    // MARK: Behaviour

    private var behaviourSection: some View {
        Section {
            Toggle("Continuar en segundo plano", isOn: $settings.backgroundAudioEnabled)
            Toggle("Modo rápido (sin búsqueda web)", isOn: $settings.fastMode)
            Toggle("Modelo ligero (respuesta más rápida)", isOn: $settings.lightweightModelMode)
            Toggle("Modo Super (OpenCode)", isOn: $settings.superModeEnabled)
        } header: {
            Text("Comportamiento")
        } footer: {
            Text("El modo rápido omite la búsqueda web. El modelo ligero usa un modelo local más pequeño. El modo Super usa OpenCode en un espacio aislado del VPS; el modelo ligero y Super son excluyentes.")
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            LabeledContent("Modelo", value: "Qwen2.5-VL 7B · Q4_K_M")
            LabeledContent("Fast", value: "Qwen2.5 7B · Q4_K_M")
            LabeledContent("Voz", value: "Kokoro (ef_dora)")
            LabeledContent("Memoria", value: "Engram")
        } header: {
            Text("Motor")
        } footer: {
            Text("Normal procesa texto e imágenes con Qwen2.5-VL. Fast usa Qwen2.5 para texto. Ambos modelos locales utilizan Q4_K_M; Super usa OpenCode.")
        }
    }
}

extension View {
    /// Faded top scroll edge. iOS 27 draws a hard divider under the top bar
    /// without this, which is why the chat, the sidebar and this sheet all opt in.
    @ViewBuilder
    func softTopEdge() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}
