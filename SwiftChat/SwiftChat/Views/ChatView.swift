//
//  ChatView.swift
//  SwiftChat
//
//  Created on 03/25/26.
//  Copyright © 2026 Sacha Servan-Schreiber. All rights reserved.
//


import SwiftUI
import SafeSFSymbols


// MARK: - ChatContainer

/// The primary SwiftUI container that holds the main chat interface and sidebar navigation.
struct ChatContainer: View {
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject private var viewModel: SwiftChat.ChatViewModel
    @Binding var selectedSection: WorkspaceSection
    let agenda: AgendaStore

    @State private var isSidebarOpen = UIDevice.current.userInterfaceIdiom == .pad
    @State private var isShowingSettings: Bool = false
    @State private var messageText = ""
    @State private var calendarDate = Date.now
    @State private var showCompletedTasks = false

    private let sidebarWidth: CGFloat = 300

    private var usesDarkChatAppearance: Bool {
        colorScheme == .dark || settings.pureBlackBackground
    }

    private var toolbarContentColor: Color {
        usesDarkChatAppearance ? .white : .black
    }

    var body: some View {
        NavigationStack {
            mainContent
        }
        .tint(settings.accentColor)
        .preferredColorScheme(selectedSection == .chat ? nil : .dark)
        // Mirrors SettingsView so the chat title and toolbar render identically
        // to the settings sheet. Forcing the scheme is what makes the top bar match;
        // the side effect is that the "pure black background" toggle no longer has
        // a visible effect, because the app is always dark.
      
        .environmentObject(viewModel)
        .onAppear {
            isSidebarOpen = false
        }
        .onChange(of: selectedSection) {
            isSidebarOpen = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            withAnimation(.easeOut(duration: 0.2)) {
                isSidebarOpen = false
            }
        }
        .fullScreenCover(isPresented: $viewModel.showImageViewer) {
            ImageViewerOverlay(
                images: viewModel.imageViewerImages,
                initialIndex: viewModel.imageViewerIndex,
                onDismiss: { viewModel.showImageViewer = false }
            )
        }
    }

    /// Negro puro cuando el usuario lo pide; si no, el gris de fondo agrupado de iOS.
    private var chatCanvas: Color {
        Color.chatBackground(isDarkMode: colorScheme == .dark, pureBlack: settings.pureBlackBackground)
    }

    private var settings: SettingsManager { .shared }

    /// Strength of the bottom red light, driven by the accent colour choice.
    private var glowIntensity: Double { isSidebarOpen ? 0.45 : 1.0 }

    /// The main content layout including chat area and sidebar
    private var mainContent: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .pad {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        if isSidebarOpen {
                            sidebar
                                .frame(width: sidebarWidth)
                                .transition(.move(edge: .leading))
                        }
                        workspaceArea
                            .frame(width: isSidebarOpen ? geometry.size.width - sidebarWidth : geometry.size.width)
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: isSidebarOpen)
            } else {
                GeometryReader { geometry in
                    let panelWidth = min(sidebarWidth, geometry.size.width * 0.82)
                    ZStack(alignment: .leading) {
                        // Keep the sidebar mounted so opening it never rebuilds the
                        // chat list during the animation. Only its transform changes.
                        sidebar
                            .frame(width: panelWidth)
                            .offset(x: isSidebarOpen ? 0 : -panelWidth)
                            .allowsHitTesting(isSidebarOpen)
                            .accessibilityHidden(!isSidebarOpen)

                        // Keep the chat at its full width while moving it aside.
                        // Shrinking it in an HStack makes both views clip on phones.
                        workspaceArea
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipShape(.rect(cornerRadius: isSidebarOpen ? 28 : 0))
                            .offset(x: isSidebarOpen ? panelWidth : 0)
                            .allowsHitTesting(!isSidebarOpen)
                            // Dim instead of blur. A blur on this subtree re-filters the whole
                            // message list on the GPU every frame of the slide, which is what
                            // made opening/closing the sidebar drop frames. Animating the alpha
                            // of one flat colour costs nothing.
                            .overlay {
                                Color.black
                                    .opacity(isSidebarOpen ? 0.22 : 0)
                                    .allowsHitTesting(false)
                            }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
                    .clipped()
                }
                .animation(.spring(response: 0.36, dampingFraction: 0.86), value: isSidebarOpen)
            }
        }
        //.softTopEdge()
        .navigationTitle(isSidebarOpen ? "" : selectedSection == .chat ? (viewModel.currentChat?.title ?? "Makima") : selectedSection.title)
        .navigationBarTitleDisplayMode(.inline)
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .scrollEdgeEffectStyle(.soft, for: .top)
        .toolbarBackground(.hidden, for: .navigationBar)

        .tint(settings.accentColor)
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: toggleSidebar) {
                    MenuToXButton(isX: isSidebarOpen)
                        .frame(width: 24, height: 24)
                        .foregroundStyle(.white)
                }
                .accessibilityLabel(isSidebarOpen ? "Close sidebar" : "Open sidebar")
            }
            // New chat and settings live in the chat view itself, not only inside the sidebar,
            // so they stay reachable when the sidebar is closed.
            //
            // This UIKit build wraps trailing toolbar items in one glass pill, and that grouping
            // is not something two ToolbarItems can opt out of: they still land in the same
            // capsule. `ToolbarSpacer` is the supported way to break that pill, putting the two
            // actions in their own separate glass groups with a gap between them.
            if #available(iOS 26.0, *), !isSidebarOpen, selectedSection == .chat {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: createNewChat) {
                        Image(systemName: SafeSFSymbol.plus.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("New chat")
                }
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: showSettings) {
                        Image(systemName: SafeSFSymbol.gearshape.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("Settings")
                }
            } else if !isSidebarOpen && selectedSection == .chat {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(action: createNewChat) {
                        Image(systemName: SafeSFSymbol.plus.name)
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("New chat")

                    Button(action: showSettings) {
                        Image(systemName: SafeSFSymbol.gearshape.name)
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("Settings")
                }
            }
        }
        .gesture(
            UIDevice.current.userInterfaceIdiom == .phone ?
            DragGesture()
                .onEnded { gesture in
                    let threshold: CGFloat = 100
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                        if isSidebarOpen {
                            if gesture.translation.width < -threshold {
                                isSidebarOpen = false
                            }
                        } else {
                            if gesture.translation.width > threshold {
                                isSidebarOpen = true
                                dismissKeyboard()
                            }
                        }
                    }
                } : nil
        )
    }

    private var sidebar: some View {
        ChatSidebar(isOpen: $isSidebarOpen, viewModel: viewModel,
                    onNewChat: createNewChat, onSettings: showSettings,
                    selectedSection: selectedSection, onSelectSection: selectSection)
            // Keep the sidebar in the same full-screen coordinate space for every
            // workspace section so its brand header never jumps vertically.
            .ignoresSafeArea()
    }

    @ViewBuilder
    private var workspaceArea: some View {
        switch selectedSection {
        case .chat: chatArea
        case .calendar:
            AgendaCalendarView(
                store: agenda,
                selectedDate: $calendarDate,
                isSidebarOpen: isSidebarOpen
            )
        case .todo:
            AgendaTodoView(
                store: agenda,
                showCompleted: $showCompletedTasks,
                isSidebarOpen: isSidebarOpen
            )
        }
    }

    private func selectSection(_ section: WorkspaceSection) {
        dismissKeyboard()
        selectedSection = section
        withAnimation(.easeOut(duration: 0.2)) { isSidebarOpen = false }
    }

    private var chatArea: some View {
        ZStack(alignment: .bottom) {
            chatCanvas

            // Ambient lamp light is part of the canvas and remains behind the input.
            BottomGlow(intensity: glowIntensity, isThinking: viewModel.isLoading)

            ChatListView(
                isDarkMode: usesDarkChatAppearance,
                isLoading: viewModel.isLoading,
                viewModel: viewModel,
                messageText: $messageText
            )
        }
        
        .onChange(of: viewModel.isLoading) { wasLoading, isLoading in
            if wasLoading && !isLoading {
                // Voice is driven by the streaming feed inside ChatViewModel, so there is
                // nothing to speak here: the utterance is already queued sentence by
                // sentence as the text arrived. Only a cancelled turn needs a hard stop.
                if viewModel.lastGenerationCancelled {
                    VoicePlaybackService.shared.stop()
                }
            }
        }
    }

    // MARK: - Actions

    private func createNewChat() {
        selectedSection = .chat
        viewModel.createNewChat()
        messageText = ""
        isSidebarOpen = false
    }

    private func showSettings() {
        isShowingSettings = true
    }

    private func toggleSidebar() {
        withAnimation {
            isSidebarOpen.toggle()
            if isSidebarOpen { dismissKeyboard() }
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

}

// MARK: - WelcomeView

struct WelcomeView: View {
    let isDarkMode: Bool

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Text("Háblale a Makima")
                    .font(.title)
                    .fontWeight(.semibold)
                    .foregroundStyle(isDarkMode ? .white : .black)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
        }
        .padding(.top, 24)
        .padding(.bottom, 4)
    }
}

// MARK: - Helper Views

/// Animated button that transforms between a menu icon and an X
struct MenuToXButton: View {
    let isX: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .frame(width: 18, height: 2)
                .rotationEffect(.degrees(isX ? 45 : 0))
                .offset(y: isX ? 0 : -6)
            Rectangle()
                .frame(width: 18, height: 2)
                .opacity(isX ? 0 : 1)
            Rectangle()
                .frame(width: 18, height: 2)
                .rotationEffect(.degrees(isX ? -45 : 0))
                .offset(y: isX ? 0 : 6)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isX)
    }
}

/// A shape for custom corner rounding
struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}

/// Extension for applying rounded corners to views
extension View {
    func corners(_ corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: 15, corners: corners))
    }

    @ViewBuilder func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }

}

// Helper extension to convert UIView.AnimationCurve to SwiftUI Animation
extension Animation {
    init(curve: UIView.AnimationCurve, duration: Double) {
        switch curve {
        case .easeInOut:
            self = .easeInOut(duration: duration)
        case .easeIn:
            self = .easeIn(duration: duration)
        case .easeOut:
            self = .easeOut(duration: duration)
        case .linear:
            self = .linear(duration: duration)
        @unknown default:
            self = .easeInOut(duration: duration)
        }
    }
}
