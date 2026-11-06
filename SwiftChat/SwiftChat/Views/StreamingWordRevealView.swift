import SwiftUI

/// Reveals streamed text word by word, each word arriving soft and settling into focus.
///
/// The reveal is paced by a timer rather than by the token stream because the goal is to
/// match the cadence of speech, not the network. The point is that the eye reads the
/// sentence being spoken instead of watching a wall of text resolve all at once.
///
/// Only used while a message is streaming. Once complete, the caller renders the normal
/// markdown view so formatting, code blocks and LaTeX are never lost.
struct StreamingWordRevealView: View {
    let content: String

    @State private var revealed = 0

    /// Observed so the reveal can be driven by the voice instead of by a timer.
    @ObservedObject private var voice = VoicePlaybackService.shared
    @ObservedObject private var settings = SettingsManager.shared

    /// Words this far behind the frontier still fade in.
    private let settleWindow = 5

    /// Fallback cadence for when nothing is listening. Speech runs near three words a
    /// second, so the timer below is deliberately slower than typing to avoid the text
    /// racing away from the audio.
    private let silentTickMs = 45

    private var isVoiceOn: Bool {
        settings.voiceModeEnabled && settings.autoPlayResponses && !settings.isMuted
    }

    private var tokens: [RevealWord] {
        content
            .split(whereSeparator: { $0.isWhitespace })
            .enumerated()
            .map { RevealWord(position: $0.offset, text: String($0.element)) }
    }

    var body: some View {
        let words = tokens
        let shown = min(revealed, words.count)

        WordFlowLayout {
            ForEach(Array(words.prefix(shown))) { word in
                RevealedWord(
                    text: word.text,
                    age: shown - 1 - word.position,
                    settleWindow: settleWindow
                )
            }
        }
            // Deliberately NOT keyed on token count. An id-based task is cancelled and
            // restarted by every incoming token, and tokens arrive far faster than a tick,
            // so the loop was killed before it ever advanced and then dumped the whole
            // message at once when the stream ended.
            .task { await revealPace() }
            // With voice on, the audio owns the frontier: words appear as they are spoken
            // rather than as they arrive, which is what makes the voice lead.
            .onChange(of: voice.spokenWordCount) { _, spoken in
                guard isVoiceOn, spoken > revealed else { return }
                revealed = min(tokens.count, spoken)
            }
    }

    /// Fallback for when nothing is listening.
    ///
    /// With voice on there is no fallback at all: the audio owns the frontier, and the
    /// screen stays empty until the first sound is actually playing. An earlier version
    /// released the text after a grace period, which is precisely the behaviour that was
    /// wrong — the words showed up first and the voice chased them. If synthesis never
    /// succeeds, the message simply stays blank while streaming and the markdown view
    /// shows the full text when the reply ends.
    private func revealPace() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(silentTickMs))
            if Task.isCancelled { return }
            if isVoiceOn { continue }

            let total = tokens.count
            guard revealed < total else {
                continue
            }

            let backlog = total - revealed
            let step = backlog > 60 ? 4 : (backlog > 25 ? 2 : 1)
            revealed = min(total, revealed + step)
        }
    }
}

private struct RevealWord: Identifiable {
    let position: Int
    let text: String

    var id: Int { position }
}

/// Owns the entrance animation for one word, keeping already-visible words sharp.
private struct RevealedWord: View {
    let text: String
    let age: Int
    let settleWindow: Int

    @State private var blurRadius: CGFloat = 3

    private var opacity: Double {
        guard age < settleWindow else { return 1 }
        return min(1, 0.28 + Double(age) * 0.20)
    }

    var body: some View {
        Text(text + " ")
            .foregroundStyle(.white.opacity(opacity))
            .blur(radius: blurRadius)
            .onAppear {
                withAnimation(.easeOut(duration: 0.30)) {
                    blurRadius = 0
                }
            }
    }
}

/// Places independently animated words with normal paragraph-style wrapping.
private struct WordFlowLayout: Layout {
    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let result = arrangement(for: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = arrangement(for: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                anchor: .topLeading,
                proposal: .unspecified
            )
        }
    }

    private func arrangement(for proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let availableWidth = proposal.width ?? .infinity
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > availableWidth {
                x = 0
                y += lineHeight
                lineHeight = 0
            }

            points.append(CGPoint(x: x, y: y))
            x += size.width
            lineHeight = max(lineHeight, size.height)
            usedWidth = max(usedWidth, x)
        }

        return (CGSize(width: min(usedWidth, availableWidth), height: y + lineHeight), points)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 20) {
        StreamingWordRevealView(
            content: "Hola User, esta respuesta aparece palabra por palabra y cada palabra se desenfoca al entrar."
        )
        LaTeXMarkdownView(content: "Y al terminar se vuelve a renderizar con markdown normal.", isDarkMode: true)
    }
    .padding()
    .foregroundStyle(.white)
    .background(Color.black)
}
