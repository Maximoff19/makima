//
//  MessageScrollView.swift
//  SwiftChat
//
//  Created on 03/25/26.
//  Copyright © 2026 Sacha Servan-Schreiber. All rights reserved.
//

import SwiftUI
import Combine

/// Scrollable message list.
///
/// This used to be a `UITableView` behind a `UIViewRepresentable`. A native
/// `ScrollView` is required for `.softTopEdge()` to do anything: SwiftUI's
/// `scrollEdgeEffectStyle` reaches real scroll views, but it cannot see through
/// a `UIViewRepresentable` into its inner `UITableView`.
///
/// Trade-offs accepted in exchange for losing cell recycling:
/// - The old per-index height caches are gone; `ScrollView` measures for itself.
/// - The streaming buffer no longer needs the `screenHeight * 50` spacer plus a
///   negative `contentInset`. Pinning to the bottom while tokens stream keeps
///   the reading position stable without inflating the layout.
struct MessageScrollView: View {
    let archivedMessagesStartIndex: Int
    let isDarkMode: Bool
    let isLoading: Bool
    @ObservedObject var viewModel: ChatViewModel
    @Binding var isAtBottom: Bool
    @Binding var userHasScrolled: Bool
    let scrollTrigger: UUID
    @Binding var tableOpacity: Double

    /// Per-message observable state. Held by reference so cells can be created
    /// lazily without churning `View` state on every body evaluation.
    @State private var store = MessageWrapperStore()
    @State private var contentFingerprint: Int = 0

    private let bottomAnchor = "makima.messageList.bottom"
    private let scrollSpace = "makima.messageList.scroll"
    /// Matches the old UITableView tolerance so the button appears at the same point.
    private let bottomSlack: CGFloat = 150

    private var messages: [Message] { viewModel.messages }

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    // The bottom marker must NOT live inside the LazyVStack. A LazyVStack only
                    // materialises the rows near the viewport, so once the user scrolled up the
                    // marker was destroyed, its preference stopped being emitted, and
                    // `isAtBottom` stayed frozen at `true` — the scroll-to-bottom button could
                    // therefore never appear. Wrapping the lazy stack in a plain VStack keeps the
                    // marker laid out at the true end of the content at all times, while the
                    // messages themselves still render lazily.
                    VStack(spacing: 0) {
                        LazyVStack(spacing: 0) {
                            if messages.isEmpty {
                                WelcomeView(isDarkMode: isDarkMode)
                                    .padding(.vertical, 16)
                                    .padding(.horizontal, UIDevice.current.userInterfaceIdiom == .pad ? 100 : 0)
                                    .frame(maxWidth: 900)
                                    .frame(maxWidth: .infinity)
                            } else {
                                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                                    if let wrapper = store.wrapper(
                                        for: message,
                                        index: index,
                                        totalCount: messages.count,
                                        isDarkMode: isDarkMode,
                                        isLoading: isLoading,
                                        archivedMessagesStartIndex: archivedMessagesStartIndex
                                    ) {
                                        ObservableMessageCell(wrapper: wrapper, viewModel: viewModel)
                                            .id(message.id)
                                    }
                                }
                            }
                        }

                        bottomMarker
                    }
                    .frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: scrollSpace)
                .scrollDismissesKeyboard(.interactively)
                // Anchor to the bottom from the very first layout. A programmatic
                // scrollTo on .onAppear is unreliable here because a LazyVStack has
                // not measured its rows yet, so the anchor does not exist and the
                // call is silently dropped — which left the chat opened at the top.
                .defaultScrollAnchor(.bottom)
                .onPreferenceChange(BottomMarkerKey.self) { markerMaxY in
                    updateBottomState(markerMaxY: markerMaxY, viewportHeight: viewport.size.height)
                }
                .onScrollPhaseChange { _, newPhase in
                    if newPhase != .idle {
                        userHasScrolled = true
                        viewModel.isScrollInteractionActive = true
                    }
                }
                // Explicit "go to the bottom" requests: new user message, chat
                // switch, and the scroll-to-bottom button all bump scrollTrigger.
                .onChange(of: scrollTrigger) {
                    scrollToBottom(proxy, animated: false)
                }
                .onChange(of: messages.count) { oldCount, newCount in
                    guard newCount > oldCount else { return }
                    let added = messages.suffix(newCount - oldCount)
                    let hasUserMessage = added.contains { $0.role == .user }
                    if hasUserMessage || oldCount == 0 {
                        scrollToBottom(proxy, animated: true)
                    }
                }
                .onChange(of: isLoading) { wasLoading, nowLoading in
                    if wasLoading && !nowLoading {
                        if isAtBottom { scrollToBottom(proxy, animated: true) }
                    }
                }
                // Keep the last row in view while tokens stream, but only when the
                // user has not scrolled away — otherwise yanking them back is hostile.
                .onChange(of: streamingContentKey) { _, _ in
                    if isLoading && isAtBottom {
                        scrollToBottom(proxy, animated: false)
                    }
                }
                .onChange(of: viewModel.currentChat?.createdAt) { _, _ in
                    scrollToBottom(proxy, animated: false)
                }
                .onAppear {
                    scrollToBottom(proxy, animated: false)
                }
            }
            // Give the scroll container a fresh identity per chat. Without this the
            // ScrollView keeps the previous chat's content offset, and a LazyVStack
            // renders nothing at a stale offset, so switching to a long chat showed
            // an empty screen until the user scrolled. Rebuilding the container also
            // re-applies .defaultScrollAnchor(.bottom) to the new content.
            .id(viewModel.currentChat?.createdAt)
        }
        .opacity(tableOpacity)
    }

    // MARK: - Scrolling

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        userHasScrolled = false
        viewModel.isScrollInteractionActive = false

        let action = { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
        if animated {
            withAnimation(.easeOut(duration: 0.25), action)
        } else {
            action()
        }
    }

    private func updateBottomState(markerMaxY: CGFloat, viewportHeight: CGFloat) {
        let atBottom = markerMaxY <= viewportHeight + bottomSlack
        guard atBottom != isAtBottom else { return }
        isAtBottom = atBottom
        viewModel.isAtBottom = atBottom
        if atBottom { userHasScrolled = false }
    }

    /// Cheap signal that the streaming body changed, so the pinned scroll can follow.
    private var streamingContentKey: String {
        guard let last = messages.last, isLoading else { return "" }
        return "\(last.id)-\(last.content.count)-\(last.contentChunks.count)-\(last.thinkingChunks.count)"
    }

    // MARK: - Bottom marker

    /// Invisible sentinel that reports how far the content extends past the viewport.
    /// The `.id(bottomAnchor)` is load-bearing: `scrollTo` targets that anchor by id, and
    /// without it every "go to the bottom" call (new message, chat switch, and the
    /// scroll-to-bottom button) silently did nothing.
    private var bottomMarker: some View {
        GeometryReader { geo in
            Color.clear
                .preference(key: BottomMarkerKey.self, value: geo.frame(in: .named(scrollSpace)).maxY)
        }
        .frame(height: 1)
        .id(bottomAnchor)
    }
}

private struct BottomMarkerKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Owns the per-message wrappers so they survive re-renders, mirroring what the
/// old `Coordinator.messageWrappers` dictionary did.
private final class MessageWrapperStore {
    private(set) var wrappers: [String: ObservableMessageWrapper] = [:]
    private var alreadyShown: Set<String> = []

    func wrapper(
        for message: Message,
        index: Int,
        totalCount: Int,
        isDarkMode: Bool,
        isLoading: Bool,
        archivedMessagesStartIndex: Int
    ) -> ObservableMessageWrapper? {
        let isLast = index == max(0, totalCount - 1)
        let isArchived = index < archivedMessagesStartIndex
        let showSeparator = index == archivedMessagesStartIndex && archivedMessagesStartIndex > 0

        if let existing = wrappers[message.id] {
            existing.update(
                message: message,
                isDarkMode: isDarkMode,
                isLastMessage: isLast,
                isLoading: isLoading,
                isArchived: isArchived,
                showArchiveSeparator: showSeparator,
                messageIndex: index
            )
            // Never re-animate a message the user has already seen.
            existing.shouldAnimateAppearance = false
            return existing
        }

        let isFirstTimeShown = !alreadyShown.contains(message.id)
        alreadyShown.insert(message.id)
        let created = ObservableMessageWrapper(
            message: message,
            isDarkMode: isDarkMode,
            isLastMessage: isLast,
            isLoading: isLoading,
            isArchived: isArchived,
            showArchiveSeparator: showSeparator,
            shouldAnimateAppearance: isFirstTimeShown,
            messageIndex: index
        )
        wrappers[message.id] = created
        return created
    }
}

class ObservableMessageWrapper: ObservableObject {
    @Published var message: Message
    @Published var isDarkMode: Bool
    @Published var isLastMessage: Bool
    @Published var isLoading: Bool
    @Published var isArchived: Bool
    @Published var showArchiveSeparator: Bool
    @Published var shouldAnimateAppearance: Bool = false
    @Published var messageIndex: Int

    init(message: Message, isDarkMode: Bool, isLastMessage: Bool, isLoading: Bool, isArchived: Bool, showArchiveSeparator: Bool, shouldAnimateAppearance: Bool = true, messageIndex: Int = 0) {
        self.message = message
        self.isDarkMode = isDarkMode
        self.isLastMessage = isLastMessage
        self.isLoading = isLoading
        self.isArchived = isArchived
        self.showArchiveSeparator = showArchiveSeparator
        self.shouldAnimateAppearance = shouldAnimateAppearance
        self.messageIndex = messageIndex
    }

    func update(message: Message, isDarkMode: Bool, isLastMessage: Bool, isLoading: Bool, isArchived: Bool, showArchiveSeparator: Bool, messageIndex: Int) {
        let contentChanged = self.message.content != message.content ||
                            self.message.thoughts != message.thoughts ||
                            self.message.contentChunks != message.contentChunks ||
                            self.message.thinkingChunks != message.thinkingChunks ||
                            self.message.isThinking != message.isThinking ||
                            self.message.isCollapsed != message.isCollapsed ||
                            self.message.generationTimeSeconds != message.generationTimeSeconds ||
                             self.message.streamError != message.streamError ||
                              self.message.checklist != message.checklist ||
                              self.message.agentActivity != message.agentActivity ||
                             self.isDarkMode != isDarkMode

        let metadataChanged = self.isLastMessage != isLastMessage ||
                              self.isLoading != isLoading ||
                              self.isArchived != isArchived ||
                              self.showArchiveSeparator != showArchiveSeparator ||
                              self.messageIndex != messageIndex

        if !contentChanged && !metadataChanged {
            return
        }

        // Defer @Published property updates to the next run loop tick.
        // UIHostingConfiguration requires the objectWillChange notification
        // to arrive on a separate run loop iteration to trigger a re-render.
        DispatchQueue.main.async {
            self.message = message
            self.isDarkMode = isDarkMode
            self.isLastMessage = isLastMessage
            self.isLoading = isLoading
            self.isArchived = isArchived
            self.showArchiveSeparator = showArchiveSeparator
            self.messageIndex = messageIndex
        }
    }
}

struct ObservableMessageCell: View {
    @ObservedObject var wrapper: ObservableMessageWrapper
    @ObservedObject var viewModel: ChatViewModel
    weak var coordinator: AnyObject?
    @State private var hasAppeared = false

    var body: some View {
        VStack(spacing: 0) {
            if wrapper.showArchiveSeparator {
                HStack(spacing: 8) {
                    Rectangle()
                        .frame(height: 1)
                        .foregroundColor(.gray)
                    Text("archived")
                        .foregroundColor(.gray)
                        .font(.system(size: 12))
                    Rectangle()
                        .frame(height: 1)
                        .foregroundColor(.gray)
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 24)
            }

            ZStack(alignment: .topLeading) {
                MessageView(
                    message: wrapper.message,
                    isDarkMode: wrapper.isDarkMode,
                    isLastMessage: wrapper.isLastMessage,
                    isLoading: wrapper.isLoading,
                    messageIndex: wrapper.messageIndex
                )
                .environmentObject(viewModel)
                .opacity(wrapper.isArchived ? 0.6 : 1.0)
                .padding(.vertical, 8)
                .padding(.horizontal, UIDevice.current.userInterfaceIdiom == .pad ? 100 : 8)
                .if(UIDevice.current.userInterfaceIdiom == .pad) { view in
                    view.frame(maxWidth: 900)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .opacity(wrapper.shouldAnimateAppearance && !hasAppeared ? 0 : 1)
        .onAppear {
            if wrapper.shouldAnimateAppearance && !hasAppeared {
                withAnimation(.easeIn(duration: 0.2)) {
                    hasAppeared = true
                }
            } else {
                hasAppeared = true
            }
        }
    }
}
