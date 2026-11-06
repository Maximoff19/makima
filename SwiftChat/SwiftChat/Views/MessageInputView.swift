//
//  MessageInputView.swift
//  SwiftChat
//
//  Created on 03/25/26.
//  Copyright © 2026 Sacha Servan-Schreiber. All rights reserved.
//

import SwiftUI
import AVFoundation
import UIKit
import PhotosUI
import SafeSFSymbols

/// Input area for typing messages, including attachments and send button
struct MessageInputView: View {
    // MARK: - Constants
    fileprivate enum Layout {
        static let defaultHeight: CGFloat = 72
        static let minimumHeight: CGFloat = 72
        static let maximumHeight: CGFloat = 180
    }

    @Binding var messageText: String
    @ObservedObject var viewModel: SwiftChat.ChatViewModel
    // Drives the speedometer in the model picker; shared so the Settings
    // toggle and this picker can never disagree.
    @ObservedObject private var settings = SettingsManager.shared
    @Environment(\.colorScheme) var colorScheme
    @State private var textHeight: CGFloat = Layout.defaultHeight

    private var isDarkMode: Bool { colorScheme == .dark }

    // Attachment picker state
    @State private var showDocumentPicker = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showCameraPermissionAlert = false
    @State private var showAttachmentDialog = false
    @State private var showModelDialog = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []

    private var showAttachmentError: Binding<Bool> {
        Binding(
            get: { viewModel.attachmentError != nil },
            set: { if !$0 { viewModel.attachmentError = nil } }
        )
    }

    @ViewBuilder
    var body: some View {
        inputContent
            .alert("Attachment Error", isPresented: showAttachmentError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.attachmentError ?? "An error occurred")
            }
            .sheet(isPresented: $showDocumentPicker) {
                DocumentPickerView { url, fileName in
                    viewModel.addDocumentAttachment(url: url, fileName: fileName)
                }
            }
            .sheet(isPresented: $showPhotoPicker, onDismiss: processSelectedPhotos) {
                NavigationStack {
                    PhotosPicker(selection: $selectedPhotoItems, matching: .images) {
                        Text("Select Photos")
                    }
                    .photosPickerStyle(.inline)
                    .navigationTitle("Select Photos")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showPhotoPicker = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPickerView { image in
                    if let data = image.jpegData(compressionQuality: CGFloat(Constants.Attachments.imageCompressionQuality)) {
                        viewModel.addImageAttachment(data: data, fileName: "Camera Photo.jpg")
                    }
                }
                .ignoresSafeArea()
            }
            .alert("Cámara", isPresented: $showCameraPermissionAlert) {
                Button("Abrir Ajustes") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Makima necesita la cámara para tomar la foto. Activala en Ajustes → Makima → Cámara.")
            }
    }

    @ViewBuilder
    private var inputContent: some View {
        if #available(iOS 26, *) {
            VStack(spacing: 16) {
                // The orb is the voice indicator, not the switch: it only exists once voice
                // mode is on in Settings, so it never adds a control to decode while off.
                // The generous spacing above lifts it clear of the composer so it reads as a
                // separate presence rather than part of the input bar.
                if settings.voiceModeEnabled {
                    VoiceOrb()
                }
                VStack(spacing: 0) {
                    if !viewModel.pendingAttachments.isEmpty {
                        AttachmentPreviewBar(
                            attachments: viewModel.pendingAttachments,
                            thumbnails: viewModel.pendingImageThumbnails,
                            onRemove: { id in viewModel.removePendingAttachment(id: id) }
                        )
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                    }

                    CustomTextEditor(text: $messageText,
                                     textHeight: $textHeight,
                                     placeholderText: viewModel.currentChat?.messages.isEmpty ?? true ? "What's on your mind?" : "Message",
                                     shouldFocusInput: viewModel.shouldFocusInput,
                                     isLoading: viewModel.isLoading,
                                     onFocusHandled: { viewModel.shouldFocusInput = false },
                                     onSendMessage: { text in viewModel.sendMessage(text: text) })
                        .frame(height: textHeight)
                        .padding(.horizontal)

                    HStack {
                        attachButton
                        modelSelector
                        Spacer()

                        Button(action: sendOrCancelMessage) {
                            Image(systemName: viewModel.isLoading ? "stop.fill" : "arrow.up")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 24, height: 24)
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 32, height: 32)
                        .background(Color(hex: "FF3B30"), in: Circle())
                        .clipShape(Circle())
                        .accessibilityLabel(viewModel.isLoading ? "Stop generating" : "Send message")
                        .padding(.trailing, 8)
                    }
                    .padding(.vertical, 8)
                }
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 32))
            }
            .padding(.horizontal, 12)
        } else {
            VStack(spacing: 16) {
                if settings.voiceModeEnabled {
                    VoiceOrb()
                }
                VStack(spacing: 0) {
                    if !viewModel.pendingAttachments.isEmpty {
                        AttachmentPreviewBar(
                            attachments: viewModel.pendingAttachments,
                            thumbnails: viewModel.pendingImageThumbnails,
                            onRemove: { id in viewModel.removePendingAttachment(id: id) }
                        )
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                    }

                    CustomTextEditor(text: $messageText,
                                     textHeight: $textHeight,
                                     placeholderText: viewModel.currentChat?.messages.isEmpty ?? true ? "What's on your mind?" : "Message",
                                     shouldFocusInput: viewModel.shouldFocusInput,
                                     isLoading: viewModel.isLoading,
                                     onFocusHandled: { viewModel.shouldFocusInput = false },
                                     onSendMessage: { text in viewModel.sendMessage(text: text) })
                        .frame(height: textHeight)
                        .padding(.horizontal)

                    HStack {
                        attachButton
                        modelSelector
                        Spacer()

                        Button(action: sendOrCancelMessage) {
                            ZStack {
                                Circle()
                                    .fill(Color(hex: "FF3B30"))
                                    .frame(width: 32, height: 32)
                                Image(systemName: viewModel.isLoading ? "stop.fill" : "arrow.up")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .accessibilityLabel(viewModel.isLoading ? "Stop generating" : "Send message")
                        .padding(.trailing, 8)
                    }
                    .padding(.vertical, 8)
                }
                .background {
                    RoundedRectangle(cornerRadius: 32)
                        .fill(.thickMaterial)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    /// Model picker for the input bar.
    ///
    /// A `Menu` containing a `Picker` was used before and it was broken twice over: the
    /// nested picker collapsed into its own submenu (so "Makima Super" was a tap deeper than
    /// users expect), and the bridged UIMenu does not present reliably from inside the
    /// `.glassEffect` bar. `confirmationDialog` is pure SwiftUI, presents from anywhere and
    /// lists every mode directly — the same fix already used by `attachButton`.
    private var modelSelector: some View {
        Button { showModelDialog = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "speedometer")
                    .font(.system(size: 17, weight: .medium))
                    // Always white: the accent colour used to encode the mode, which meant the
                    // icon changed meaning between modes and read as disabled in the neutral one.
                    .foregroundStyle(.white)
                Text(activeModelLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Response model")
        .accessibilityValue(activeModelLabel)
        // The dialog inherits the app accent (red) by default, which fought the white icon
        // next to it. Force the tint so the mode names read in white on the dark glass.
        .tint(.white)
        .confirmationDialog("Response model", isPresented: $showModelDialog, titleVisibility: .visible) {
            Button {
                modelSelection.wrappedValue = .standard
            } label: {
                Text("Makima").foregroundStyle(.white)
            }
            Button {
                modelSelection.wrappedValue = .lightweight
            } label: {
                Text("Makima Fast").foregroundStyle(.white)
            }
            Button {
                modelSelection.wrappedValue = .superMode
            } label: {
                Text("Makima Super").foregroundStyle(.white)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var activeModelLabel: String {
        if settings.superModeEnabled { return "Super" }
        return settings.lightweightModelMode ? "Fast" : "Makima"
    }

    private var modelSelection: Binding<FastModelChoice> {
        Binding(
            get: {
                if settings.superModeEnabled { return .superMode }
                return settings.lightweightModelMode ? .lightweight : .standard
            },
            set: { choice in
                settings.superModeEnabled = choice == .superMode
                settings.lightweightModelMode = choice == .lightweight
            }
        )
    }

    @ViewBuilder
    private var attachButton: some View {
        // A Menu bridges to a UIKit UIMenu, which does not present reliably from inside the
        // .glassEffect input bar — the tap opened nothing. A confirmationDialog is pure SwiftUI and
        // presents from anywhere, while looking the same to the user.
        Button { showAttachmentDialog = true } label: {
            Image(.plus)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Add attachment")
        .confirmationDialog("Add to Chat", isPresented: $showAttachmentDialog, titleVisibility: .visible) {
            Button("Camera") {
                // Asking first avoids presenting a picker that iOS will only kill,
                // and gives a real explanation when access was previously denied.
                switch AVCaptureDevice.authorizationStatus(for: .video) {
                case .authorized:
                    showCamera = true
                case .notDetermined:
                    AVCaptureDevice.requestAccess(for: .video) { granted in
                        Task { @MainActor in
                            if granted { showCamera = true } else { showCameraPermissionAlert = true }
                        }
                    }
                default:
                    showCameraPermissionAlert = true
                }
            }
            Button("Photos") { showPhotoPicker = true }
            Button("Files") { showDocumentPicker = true }
            Button("Cancel", role: .cancel) {}
        }
        .tint(.white)
    }

    private func sendOrCancelMessage() {
        if viewModel.isLoading {
            viewModel.cancelGeneration()
        } else if !messageText.isEmpty || !viewModel.pendingAttachments.isEmpty {
            viewModel.sendMessage(text: messageText)
            messageText = ""
            textHeight = Layout.defaultHeight
        }
    }

    private func processSelectedPhotos() {
        let items = selectedPhotoItems
        selectedPhotoItems = []
        for (index, item) in items.enumerated() {
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    let fileName = items.count > 1 ? "Photo \(index + 1).jpg" : "Photo.jpg"
                    viewModel.addImageAttachment(data: data, fileName: fileName)
                }
            }
        }
    }
}

/// Custom UIViewRepresentable for a properly managed text editor
struct CustomTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var textHeight: CGFloat
    var placeholderText: String
    var shouldFocusInput: Bool
    var isLoading: Bool
    var onFocusHandled: () -> Void
    var onSendMessage: (String) -> Void

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.isScrollEnabled = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.alwaysBounceVertical = false
        textView.scrollsToTop = false
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 2, bottom: 8, right: 5)
        textView.textContainer.lineFragmentPadding = 0
        textView.tintColor = UIColor.systemBlue

        if text.isEmpty {
            textView.text = placeholderText
            textView.textColor = .lightGray
        } else {
            textView.text = text
            textView.textColor = UIColor { traitCollection in
                return traitCollection.userInterfaceStyle == .dark ? .white : .black
            }
        }

        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        let isCurrentlyEditing = context.coordinator.isEditing

        if shouldFocusInput && !context.coordinator.hasFocusedFromFlag {
            context.coordinator.hasFocusedFromFlag = true
            DispatchQueue.main.async {
                if !uiView.isFirstResponder { uiView.becomeFirstResponder() }
                self.onFocusHandled()
            }
        } else if !shouldFocusInput {
            context.coordinator.hasFocusedFromFlag = false
        }

        if text.isEmpty && !isCurrentlyEditing && uiView.textColor != .lightGray {
            uiView.text = placeholderText
            uiView.textColor = .lightGray
        } else if text.isEmpty && isCurrentlyEditing {
            if uiView.text.isEmpty && uiView.textColor == .lightGray {
                uiView.text = ""
                uiView.textColor = UIColor { tc in tc.userInterfaceStyle == .dark ? .white : .black }
            } else if !uiView.text.isEmpty && uiView.textColor != .lightGray {
                self.text = uiView.text
            }
        } else if !text.isEmpty && uiView.textColor == .lightGray {
            uiView.text = text
            uiView.textColor = UIColor { tc in tc.userInterfaceStyle == .dark ? .white : .black }
        } else if !text.isEmpty && uiView.text != text && uiView.textColor != .lightGray {
            uiView.text = text
        }

        uiView.isEditable = true

        let size = uiView.sizeThatFits(CGSize(width: uiView.frame.width, height: CGFloat.greatestFiniteMagnitude))
        let newHeight = min(MessageInputView.Layout.maximumHeight, max(MessageInputView.Layout.minimumHeight, size.height))
        if textHeight != newHeight {
            DispatchQueue.main.async { self.textHeight = newHeight }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: CustomTextEditor
        var isEditing = false
        var hasFocusedFromFlag = false

        init(_ parent: CustomTextEditor) { self.parent = parent }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n" {
                let isMac = ProcessInfo.processInfo.isiOSAppOnMac
                if isMac {
                    let currentText = textView.text ?? ""
                    let trimmedText = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedText.isEmpty && !parent.isLoading {
                        parent.onSendMessage(trimmedText)
                        textView.text = ""
                        parent.text = ""
                        parent.textHeight = MessageInputView.Layout.defaultHeight
                        textView.text = parent.placeholderText
                        textView.textColor = .lightGray
                        textView.resignFirstResponder()
                    }
                    return false
                }
            }

            let currentText = textView.text as NSString
            let newText = currentText.replacingCharacters(in: range, with: text)
            if newText.isEmpty && isEditing { return true }
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            if textView.textColor != .lightGray {
                parent.text = textView.text
                let size = textView.sizeThatFits(CGSize(width: textView.frame.width, height: CGFloat.greatestFiniteMagnitude))
                let newHeight = min(MessageInputView.Layout.maximumHeight, max(MessageInputView.Layout.minimumHeight, size.height))
                if parent.textHeight != newHeight { parent.textHeight = newHeight }
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            isEditing = true
            if textView.textColor == .lightGray {
                textView.text = ""
                textView.textColor = UIColor { tc in tc.userInterfaceStyle == .dark ? .white : .black }
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            isEditing = false
            if textView.text.isEmpty {
                textView.text = parent.placeholderText
                textView.textColor = .lightGray
            }
        }
    }
}
