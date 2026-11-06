import SwiftUI
import SafeSFSymbols

/// Voice control shown as a white orb with red nebula drifting inside it.
///
/// This replaces a capsule button that sat above the composer. A button read as another
/// control to decode; an orb reads as the thing itself — Makima's presence — and the cloud
/// deforming while she talks answers "is it speaking?" without any text.
struct VoiceOrb: View {
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var voice = VoicePlaybackService.shared

    private let size: CGFloat = 72
    private var isOn: Bool {
        settings.voiceModeEnabled && settings.autoPlayResponses && !settings.isMuted
    }

    var body: some View {
        Button {
            settings.voiceModeEnabled.toggle()
            if !settings.voiceModeEnabled {
                VoicePlaybackService.shared.stop()
            }
        } label: {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let energy = voice.isSpeaking ? 1.0 : 0.0
                // Levitation: the orb leaves the surface while she talks. The lift plus a
                // slow bob reads as floating, and the widening shadow below sells the height.
                let lift = energy * (9 + 3.5 * sin(t * 2.0))

                orb(t: t, energy: energy, lift: lift)
                    // Breathing while silent, a soft wobble while speaking.
                    .scaleEffect(
                        x: 1 + 0.045 * energy * sin(t * 6.1) + 0.012 * sin(t * 1.3),
                        y: 1 - 0.045 * energy * sin(t * 6.1) - 0.012 * sin(t * 1.3),
                        anchor: .center
                    )
                    .offset(
                        x: 3 * energy * sin(t * 3.7),
                        y: -lift + 2.5 * energy * cos(t * 4.3)
                    )
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "Turn voice off" : "Turn voice on")
        .accessibilityValue(voice.isSpeaking ? "Speaking" : (isOn ? "On" : "Off"))
    }

    // MARK: - Orb

    private func orb(t: TimeInterval, energy: Double, lift: Double) -> some View {
        Canvas { context, canvasSize in
            let rect = CGRect(origin: .zero, size: canvasSize)
            let circle = Path(ellipseIn: rect)
            let side = canvasSize.width

            // White shell first: the orb must stay white, with colour living inside it.
            context.fill(circle, with: .color(.white))

            // Red nebula, clipped so the clouds never escape the orb.
            context.clip(to: circle)
            let speed = 0.32 + 0.55 * energy
            let blobs: [(Double, Double, Double, Double, Double)] = [
                // (x, y, radius, alpha, phase) - small and spread so white shows through.
                (0.34, 0.36, 0.19, 0.70, 0.0),
                (0.62, 0.44, 0.15, 0.58, 1.9),
                (0.46, 0.66, 0.17, 0.62, 3.6),
                (0.70, 0.70, 0.11, 0.44, 5.3),
                (0.24, 0.62, 0.10, 0.38, 7.1),
            ]
            for (fx, fy, fr, alpha, phase) in blobs {
                let x = fx * side + 0.05 * side * sin(t * speed + phase)
                let y = fy * side + 0.05 * side * cos(t * speed * 1.3 + phase)
                let r = fr * side * (1 + 0.10 * energy * sin(t * 4 + phase))
                var blob = context
                // Heavy blur is what turns circles into clouds.
                blob.addFilter(.blur(radius: side * 0.13))
                blob.fill(
                    Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                    with: .color(Color(hex: "E8112D").opacity(alpha * (0.5 + 0.5 * energy)))
                )
            }

            // White vignette pulls the edge back to white so the orb reads as a white
            // sphere with clouds suspended in it rather than a red ball.
            let rim = context
            rim.fill(
                circle,
                with: .radialGradient(
                    Gradient(colors: [
                        .white.opacity(0),
                        .white.opacity(0.55),
                        .white.opacity(0.92),
                    ]),
                    center: CGPoint(x: side / 2, y: side / 2),
                    startRadius: side * 0.30,
                    endRadius: side * 0.52
                )
            )
        }
        // The shadow tracks height: as the orb rises it detaches, spreads and fades.
        // A shadow that stayed welded to the orb would kill the illusion of levitation.
        .shadow(
            color: isOn ? Color(hex: "E8112D").opacity((0.35 + 0.25 * energy) * (1 - 0.35 * lift / 13)) : .clear,
            radius: 8 + 10 * energy + 1.6 * lift,
            y: 3 + lift
        )
    }
}

#Preview {
    VStack(spacing: 28) {
        VoiceOrb()
    }
    .padding(40)
    .background(Color.black)
}
