import SwiftUI

/// Ambient red light projected upward from below the screen.
struct BottomGlow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var color: Color = Color(hex: "FF3B30")
    var intensity: Double = 1.0
    var isThinking = false

    @State private var waveExpanded = false
    @State private var activityLevel = 0.0

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let beamHeight = min(height * 0.52, 460)
            let pulseBoost = waveExpanded ? 0.40 : -0.12
            let animatedIntensity = intensity * (1 + activityLevel * pulseBoost)
            let horizontalShift = reduceMotion
                ? 0
                : (waveExpanded ? width * 0.075 : -width * 0.075) * activityLevel
            let horizontalScale = reduceMotion
                ? 1
                : 1 + activityLevel * (waveExpanded ? 0.035 : -0.018)
            let verticalScale = reduceMotion
                ? 1
                : 1 + activityLevel * (waveExpanded ? 0.055 : -0.025)

            ZStack(alignment: .bottom) {
                UpwardLightBeam()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: color.opacity(0), location: 0),
                                .init(color: color.opacity(0.08 * animatedIntensity), location: 0.34),
                                .init(color: color.opacity(0.24 * animatedIntensity), location: 0.72),
                                .init(color: color.opacity(0.52 * animatedIntensity), location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: width * 1.18, height: beamHeight)
                    .offset(x: horizontalShift * 0.65)
                    .blur(radius: 52)

                Ellipse()
                    .fill(
                        RadialGradient(
                            stops: [
                                .init(color: color.opacity(0.70 * animatedIntensity), location: 0),
                                .init(color: color.opacity(0.28 * animatedIntensity), location: 0.34),
                                .init(color: color.opacity(0), location: 1),
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: width * 0.58
                        )
                    )
                    .frame(width: width * 1.28, height: 150)
                    .offset(x: -horizontalShift * 0.75, y: 62)
                    .blur(radius: 44)

                // The wide, flat ellipse is the horizontal spread of the orb: a low, stretched
                // ellipse (wider than the screen, very short) laid under the gradient shapes.
                // It is soft-edged on purpose so it reads as light washing across the bottom
                // rather than a hard band.
                Ellipse()
                    .fill(
                        RadialGradient(
                            stops: [
                                .init(color: color.opacity(0.42 * animatedIntensity), location: 0),
                                .init(color: color.opacity(0.16 * animatedIntensity), location: 0.55),
                                .init(color: color.opacity(0), location: 1),
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: width * 0.95
                        )
                    )
                    .frame(width: width * 1.9, height: 64)
                    .offset(x: horizontalShift * 1.2, y: 20)
                    .blur(radius: 50)
            }
            .scaleEffect(x: horizontalScale, y: verticalScale, anchor: .bottom)
            .frame(width: width, height: height, alignment: .bottom)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea(.container, edges: .bottom)
        .accessibilityHidden(true)
        .onAppear {
            updateAnimation(isActive: isThinking)
        }
        .onChange(of: isThinking) { _, isActive in
            updateAnimation(isActive: isActive)
        }
        .onChange(of: reduceMotion) { _, _ in
            updateAnimation(isActive: isThinking)
        }
    }

    private func updateAnimation(isActive: Bool) {
        if isActive {
            withAnimation(.easeInOut(duration: 0.45)) {
                activityLevel = 1
            }

            guard !reduceMotion else {
                waveExpanded = false
                return
            }

            waveExpanded = false
            withAnimation(.easeInOut(duration: 1.65).repeatForever(autoreverses: true)) {
                waveExpanded = true
            }
        } else {
            withAnimation(.easeOut(duration: 1.5)) {
                activityLevel = 0
                waveExpanded = false
            }
        }
    }
}

/// A lamp beam with a narrow source at the bottom that spreads upward.
private struct UpwardLightBeam: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX - rect.width * 0.12, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.width * 0.04, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.width * 0.96, y: rect.minY),
            control: CGPoint(x: rect.midX, y: rect.height * 0.12)
        )
        path.addLine(to: CGPoint(x: rect.midX + rect.width * 0.12, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
