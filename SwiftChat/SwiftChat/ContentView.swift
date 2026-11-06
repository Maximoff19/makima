//
//  ContentView.swift
//  SwiftChat
//
//  Created on 03/25/26.
//  Copyright © 2026 Sacha Servan-Schreiber. All rights reserved.
//

import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var viewModel = ChatViewModel()
    @State private var showAPIKeyPrompt = false
    @State private var apiKeyInput = ""
    @State private var hostInput = ""
    @State private var setupError = ""
    @State private var isShowingLaunchIntro = true
    @State private var agenda = AgendaStore.shared
    @State private var selectedSection = WorkspaceSection.chat
    @Environment(\.scenePhase) private var scenePhase

    private var needsAPIKey: Bool {
        let key = AppConfig.shared.apiKey
        return key.isEmpty || AppConfig.shared.apiHost.isEmpty
    }

    var body: some View {
        ZStack {
            ChatContainer(selectedSection: $selectedSection, agenda: agenda)
                .environmentObject(viewModel)

            if isShowingLaunchIntro {
                LaunchIntroView {
                    isShowingLaunchIntro = false
                    prepareConnectionPrompt()
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .task(id: scenePhase) {
            viewModel.responseSceneChanged(scenePhase)
            guard scenePhase == .active else { return }
            await ChatArchive.retryDeletions()
            await agenda.reconcileNotifications()
            while !Task.isCancelled {
                await refreshAgenda()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        .onChange(of: viewModel.isLoading) {
            if !viewModel.isLoading { Task { await refreshAgenda() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .agendaReminderOpened)) { _ in
            Task { await refreshAgenda() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .responseReminderOpened)) { _ in
            selectedSection = .chat
            viewModel.openResponseReminderIfNeeded()
        }
        .alert("Connect to Makima", isPresented: $showAPIKeyPrompt) {
                TextField("Gateway domain (e.g. makima.example.com)", text: $hostInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Gateway token", text: $apiKeyInput)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Save") {
                    let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    let host = hostInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.count >= 32, host.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil,
                          host.contains("."), MakimaCredential.save(trimmed) else {
                        setupError = "Enter a valid HTTPS domain and gateway token (32+ characters)."
                        return
                    }
                    AppConfig.shared.apiKey = trimmed
                    AppConfig.shared.apiHost = host
                    UserDefaults.standard.set(host, forKey: "makimaHost")
                    UserDefaults.standard.removeObject(forKey: "apiKey")
                    viewModel.reconfigureClient()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter the HTTPS domain and token provisioned on your private VPS.")
            }
            .alert("Connection setup failed", isPresented: Binding(get: { !setupError.isEmpty }, set: { if !$0 { setupError = "" } })) {
                Button("Retry") { showAPIKeyPrompt = true }
            } message: { Text(setupError) }
    }

    @MainActor
    private func refreshAgenda() async {
        await agenda.refresh()
        let opened = UserDefaults.standard.string(forKey: "agenda.openReminderID")
        guard !viewModel.chats.contains(where: { $0.hasActiveStream }) else { return }
        viewModel.receiveAgendaReminders(agenda.dueReminders(), openReminderID: opened)
        if opened != nil {
            selectedSection = .chat
            UserDefaults.standard.removeObject(forKey: "agenda.openReminderID")
        }
    }

    private func prepareConnectionPrompt() {
        UserDefaults.standard.removeObject(forKey: "apiKey")
        if needsAPIKey {
            hostInput = AppConfig.shared.apiHost
            showAPIKeyPrompt = true
        }
    }
}

private struct LaunchIntroView: View {
    let onComplete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var layersAreOpen = false
    @State private var typedName = ""
    @State private var overlayOpacity = 1.0

    private let fullName = "MAKIMA"

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black

                Image("launch-background")
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                VStack(spacing: 5) {
                    Text(typedName)
                        .font(UIFont(name: "AWAKENNINGPersonalUse", size: 44) == nil
                              ? .system(size: 44, weight: .bold)
                              : .custom("AWAKENNINGPersonalUse", fixedSize: 44))
                        .tracking(2)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.85), radius: 8)

                    Text("by cuylabs")
                        .font(.system(size: 10, weight: .light, design: .rounded))
                        .tracking(2.2)
                        .textCase(.lowercase)
                        .foregroundStyle(.white.opacity(0.58))
                        .shadow(color: .black.opacity(0.75), radius: 5)
                        .opacity(typedName == fullName ? 1 : 0)
                        .animation(.easeIn(duration: 0.5), value: typedName == fullName)
                }
                .frame(width: proxy.size.width, alignment: .center)
                .offset(y: proxy.size.height * 0.28)
                .zIndex(1)

                Image("launch-top-layer")
                    .resizable()
                    .scaledToFit()
                    .frame(width: proxy.size.width)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .offset(y: layersAreOpen ? -(proxy.size.height * 0.12) : 0)

                Image("launch-bottom-layer")
                    .resizable()
                    .scaledToFit()
                    .frame(width: proxy.size.width)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .offset(y: layersAreOpen ? proxy.size.height * 0.045 : 0)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(.black)
        .opacity(overlayOpacity)
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .task {
            await playAnimation()
        }
    }

    @MainActor
    private func playAnimation() async {
        if reduceMotion {
            layersAreOpen = true
            typedName = fullName
            try? await Task.sleep(for: .milliseconds(3_000))
        } else {
            try? await Task.sleep(for: .milliseconds(300))

            withAnimation(.easeInOut(duration: 1.55)) {
                layersAreOpen = true
            }

            for character in fullName {
                guard !Task.isCancelled else { return }
                typedName.append(character)
                try? await Task.sleep(for: .milliseconds(220))
            }

            try? await Task.sleep(for: .milliseconds(3_000))
        }

        withAnimation(.easeOut(duration: 0.45)) {
            overlayOpacity = 0
        }
        try? await Task.sleep(for: .milliseconds(450))
        onComplete()
    }
}
