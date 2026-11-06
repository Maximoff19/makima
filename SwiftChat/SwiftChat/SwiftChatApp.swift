//
//  SwiftChatApp.swift
//  SwiftChat
//
//  Created on 03/25/26.
//  Copyright © 2026 Sacha Servan-Schreiber. All rights reserved.
//

import SwiftUI
import UserNotifications

@main
struct SwiftChatApp: App {
    init() {
        MainActor.assumeIsolated {
            UNUserNotificationCenter.current().delegate = AgendaNotificationDelegate.shared
            // Ask for camera and mic up front, then keep audio alive in background.
            PermissionPrimer.requestEssentialsIfNeeded()
            // Lets Makima notify the user when a streamed answer finishes.
            NotificationService.requestAuthorization()
            BackgroundAudioController.shared.refresh()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
