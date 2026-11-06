//
//  ChatListView.swift
//  SwiftChat
//
//  Created on 03/25/26.
//  Copyright © 2026 Sacha Servan-Schreiber. All rights reserved.
//

import SwiftUI

struct ChatListView: View {
    let isDarkMode: Bool
    let isLoading: Bool
    @ObservedObject var viewModel: SwiftChat.ChatViewModel
    @ObservedObject private var settings = SettingsManager.shared
    @Binding var messageText: String

    @State private var isAtBottom = true
    @State private var userHasScrolled = false
    @State private var isKeyboardVisible = false
    @State private var scrollTrigger = UUID()
    @State private var tableOpacity = 1.0

    private var messages: [Message] {
        viewModel.messages
    }

    private var archivedMessagesStartIndex: Int {
        max(0, messages.count - settings.maxMessages)
    }

    var body: some View {
        MessageScrollView(
            archivedMessagesStartIndex: archivedMessagesStartIndex,
            isDarkMode: isDarkMode,
            isLoading: isLoading,
            viewModel: viewModel,
            isAtBottom: $isAtBottom,
            userHasScrolled: $userHasScrolled,
            scrollTrigger: scrollTrigger,
            tableOpacity: $tableOpacity
        )
        .softTopEdge()
        .opacity(tableOpacity)
        .overlay(alignment: .bottom) {
            if !isAtBottom && !messages.isEmpty && !isKeyboardVisible {
                Button(action: {
                    userHasScrolled = false
                    viewModel.isScrollInteractionActive = false
                    scrollTrigger = UUID()
                }) {
                    ZStack {
                        Circle()
                            .fill(SettingsManager.shared.accentColor)

                        Image(systemName: "arrow.down")
                            .symbolRenderingMode(.monochrome)
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                    // No shadow here. A glow drawn in the accent colour bled sideways into a
                    // red streak across the message list; the flat disc reads clearly on its own.
                    .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Scroll to bottom")
                .padding(.bottom, 16)
                .transition(.opacity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MessageInputView(
                messageText: $messageText,
                viewModel: viewModel
            )
            .environmentObject(viewModel)
            .padding(.bottom, 10)
            .if(UIDevice.current.userInterfaceIdiom == .pad) { view in
                HStack {
                    Spacer()
                    view.frame(maxWidth: 600)
                    Spacer()
                }
            }
        }
        // Keyboard visibility gates the scroll-to-bottom button, so it has to be correct.
        // Only listening to will-show/will-hide was not enough: with
        // .scrollDismissesKeyboard(.interactively) a `willHide` can be missed (swipe the
        // keyboard away, switch apps, open a sheet), and the flag would stay `true` forever,
        // so the button never reappeared. `didHide` plus the frame-change notification cover
        // the cases `willHide` drops, and a nil frame means the keyboard is gone.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            isKeyboardVisible = (frame?.height ?? 0) > 0
        }
        .onDisappear {
            viewModel.isScrollInteractionActive = false
        }
        .onChange(of: messages.count) { oldCount, newCount in
            if newCount > oldCount {
                let newMessages = messages.suffix(newCount - oldCount)
                let hasUserMessage = newMessages.contains { $0.role == .user }
                let wasInitialLoad = oldCount == 0

                if hasUserMessage || wasInitialLoad {
                    userHasScrolled = false
                    viewModel.isScrollInteractionActive = false
                    scrollTrigger = UUID()
                }
            }
        }
        .onChange(of: viewModel.currentChat?.createdAt) { _, _ in
            userHasScrolled = false
            viewModel.isScrollInteractionActive = false

            let isNewEmptyChat = viewModel.currentChat?.isBlankChat ?? true

            if !isNewEmptyChat {
                tableOpacity = 0
                scrollTrigger = UUID()
                isAtBottom = true
                // Fade back in once the new rows are in place. The hide was written
                // for the fade transition, but nothing ever restored the opacity for
                // a chat with messages, so switching to any existing chat left the
                // whole list invisible -- the content was there, just at alpha 0.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    tableOpacity = 1.0
                }
            } else {
                tableOpacity = 1.0
                isAtBottom = true
            }
        }
        .onChange(of: viewModel.scrollToBottomTrigger) { _, _ in
            userHasScrolled = false
            viewModel.isScrollInteractionActive = false
            scrollTrigger = UUID()
        }
    }

}
