import SwiftUI

// MARK: - Calendar

struct AgendaCalendarView: View {

    @Bindable var store: AgendaStore
    @Binding var selectedDate: Date
    let isSidebarOpen: Bool

    @State private var editingItem: AgendaItem?
    @State private var exportingItem: AgendaItem?

    private var events: [AgendaItem] {
        store.snapshot.items
            .filter { $0.occurs(on: selectedDate) }
            .sorted {
                ($0.displayDate ?? .distantFuture)
                    < ($1.displayDate ?? .distantFuture)
            }
    }

    private var tasks: [AgendaItem] {
        store.snapshot.items.filter {
            $0.fields.kind == .task
                && !$0.fields.completed
                && $0.fields.dueAt.map {
                    Calendar.current.isDate(
                        $0,
                        inSameDayAs: selectedDate
                    )
                } == true
        }
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 24) {

            AgendaSection {
                DatePicker(
                    "Selected day",
                    selection: $selectedDate,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
            }

            AgendaSection(
                selectedDate.formatted(
                    date: .complete,
                    time: .omitted
                )
            ) {

                if events.isEmpty {
                    Label(
                        "No events for this day",
                        systemImage: "calendar"
                    )
                    .foregroundStyle(.secondary)
                }

                ForEach(events) { item in
                    HStack {

                        Button {
                            editingItem = item
                        } label: {
                            AgendaItemRow(item: item)
                        }
                        .buttonStyle(.plain)

                        Button {
                            exportingItem = item
                        } label: {
                            Image(systemName: "calendar.badge.plus")
                                .frame(
                                    minWidth: 44,
                                    minHeight: 44
                                )
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(
                            "Add \(item.fields.title) to Apple Calendar"
                        )
                    }
                    .contextMenu {
                        Button {
                            exportingItem = item
                        } label: {
                            Label(
                                "Export",
                                systemImage: "calendar.badge.plus"
                            )
                        }
                        .tint(.blue)
                    }
                }
            }

            if !tasks.isEmpty {
                AgendaSection("Tasks due this day") {
                    ForEach(tasks) { item in
                        Button {
                            editingItem = item
                        } label: {
                            AgendaItemRow(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            AgendaStatusSection(store: store)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .background(AgendaRefreshControl())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentMargins(.top, 56, for: .scrollContent)
        .softTopEdge()
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.always)
        .background(Color.black)

        .toolbar {

            if !isSidebarOpen {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(
                        "Add event",
                        systemImage: "plus"
                    ) {
                        let date = Calendar.current.date(
                            bySettingHour: 9,
                            minute: 0,
                            second: 0,
                            of: selectedDate
                        ) ?? selectedDate

                        editingItem = .draft(
                            .event,
                            date: date
                        )
                    }
                }

            }
        }
        .refreshable {
            await store.refresh()
        }
        .sheet(item: $editingItem) { item in
            AgendaEditorView(
                item: item,
                store: store
            )
        }
        .sheet(item: $exportingItem) { item in
            AppleCalendarExportView(item: item)
        }
    }
}


// MARK: - Todo

struct AgendaTodoView: View {

    @Bindable var store: AgendaStore
    @Binding var showCompleted: Bool
    let isSidebarOpen: Bool

    @State private var editingItem: AgendaItem?

    private var tasks: [AgendaItem] {
        store.snapshot.items
            .filter {
                $0.fields.kind == .task
                    && $0.fields.completed == showCompleted
            }
            .sorted {
                (
                    $0.fields.dueAt ?? .distantFuture,
                    $0.fields.title
                )
                <
                (
                    $1.fields.dueAt ?? .distantFuture,
                    $1.fields.title
                )
            }
    }

    private var checkins: [AgendaItem] {
        store.snapshot.items
            .filter {
                $0.fields.kind == .reminder
            }
            .sorted {
                ($0.fields.reminderAt ?? .distantFuture)
                    < ($1.fields.reminderAt ?? .distantFuture)
            }
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 24) {

            AgendaSection {
                Picker(
                    "Task status",
                    selection: $showCompleted
                ) {
                    Text("Pending")
                        .tag(false)

                    Text("Completed")
                        .tag(true)
                }
                .pickerStyle(.segmented)
            }

            AgendaSection(
                showCompleted
                    ? "Completed tasks"
                    : "Your next steps"
            ) {

                if tasks.isEmpty {
                    Label(
                        showCompleted
                            ? "No completed tasks yet"
                            : "Nothing pending",
                        systemImage: "checkmark.circle"
                    )
                    .foregroundStyle(.secondary)
                }

                ForEach(tasks) { item in
                    HStack(spacing: 8) {

                        Button {
                            var changed = item
                            changed.fields.completed.toggle()

                            Task {
                                await store.save(changed)
                            }

                        } label: {
                            Image(
                                systemName:
                                    item.fields.completed
                                    ? "checkmark.circle.fill"
                                    : "circle"
                            )
                            .font(.title2)
                            .frame(
                                minWidth: 44,
                                minHeight: 44
                            )
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(
                            item.fields.completed
                                ? "Reopen \(item.fields.title)"
                                : "Complete \(item.fields.title)"
                        )
                        .disabled(
                            store.isSaving
                                || store.isRefreshing
                        )

                        Button {
                            editingItem = item
                        } label: {
                            AgendaItemRow(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            AgendaSection(
                "Scheduled check-ins",
                footer: "Ask Super Makima in chat to create tasks or remind you about a pending item. Completing a task stops its check-ins."
            ) {

                ForEach(checkins) { item in
                    Button {
                        editingItem = item
                    } label: {
                        AgendaItemRow(item: item)
                    }
                    .buttonStyle(.plain)
                }

                Button(
                    "Schedule a check-in",
                    systemImage: "bell.badge"
                ) {
                    editingItem = .draft(.reminder)
                }

            }

            AgendaStatusSection(store: store)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .background(AgendaRefreshControl())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentMargins(.top, 56, for: .scrollContent)
        .softTopEdge()
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.always)
        .background(Color.black)
        .toolbar {

            if !isSidebarOpen {
                ToolbarItem(
                    placement: .topBarTrailing
                ) {
                    Button(
                        "Add task",
                        systemImage: "plus"
                    ) {
                        editingItem = .draft(.task)
                    }
                }
            }
        }
        .refreshable {
            await store.refresh()
        }
        .sheet(item: $editingItem) { item in
            AgendaEditorView(
                item: item,
                store: store
            )
        }
    }
}


// MARK: - Agenda Row

private struct AgendaItemRow: View {

    let item: AgendaItem

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 4
        ) {

            Text(item.fields.title)
                .font(.headline)
                .strikethrough(
                    item.fields.completed
                )

            if let date = item.displayDate {
                Label(
                    date.formatted(
                        date: .abbreviated,
                        time: .shortened
                    ),
                    systemImage: item.fields.kind.symbol
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            if let end = item.fields.endAt {
                Text(
                    "Until \(end.formatted(date: .abbreviated, time: .shortened))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if item.fields.reminderAt != nil {
                let reminderDescription = item.fields.repeat == .none
                    ? "Reminder scheduled"
                    : "\(item.fields.repeat.title) check-in"

                if item.fields.kind == .reminder {
                    Text(reminderDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label(reminderDescription, systemImage: "bell")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if item.fields.completed
                && item.fields.kind == .reminder {

                Text("Paused")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: 44,
            alignment: .leading
        )
        .foregroundStyle(.primary)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}


// MARK: - Status

private struct AgendaStatusSection: View {

    @Bindable var store: AgendaStore

    var body: some View {
        AgendaSection(
            "Delivery & sync",
            footer: "Enable notifications to receive scheduled check-ins with the app closed. This schedules reminders already synced to this iPhone; changes made while it is offline are picked up next time you open it."
        ) {

            Toggle(
                "Reminder notifications",
                isOn: Binding(
                    get: {
                        store.notificationsEnabled
                    },
                    set: { enabled in
                        Task {
                            await store
                                .setNotificationsEnabled(
                                    enabled
                                )
                        }
                    }
                )
            )

            if !store.notificationStatus.isEmpty {
                Text(store.notificationStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if store.notificationsEnabled {
                Text(
                    "Synced reminder coverage: \(store.snapshot.coverageUntil.formatted(date: .abbreviated, time: .shortened)). Open the app regularly to renew repeating reminders."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if let error = store.error {
                Label(
                    error,
                    systemImage:
                        "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.red)
            }

            Button {
                Task {
                    await store.refresh()
                }
            } label: {
                HStack {
                    Label(
                        "Sync agenda",
                        systemImage: "arrow.clockwise"
                    )

                    if store.isRefreshing {
                        ProgressView()
                    }
                }
            }
            .disabled(
                store.isRefreshing
                    || store.isSaving
            )

            if let synced = store.lastSyncedAt {
                Text(
                    "Last synced \(synced.formatted(date: .omitted, time: .shortened))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

        }
    }
}


// MARK: - Editor

struct AgendaEditorView: View {

    let item: AgendaItem

    @Bindable var store: AgendaStore

    @Environment(\.dismiss)
    private var dismiss

    @State private var fields: AgendaFields
    @State private var hasDueDate: Bool
    @State private var hasReminder: Bool
    @State private var confirmDelete = false

    init(
        item: AgendaItem,
        store: AgendaStore
    ) {
        self.item = item
        self.store = store

        _fields = State(
            initialValue: item.fields
        )

        _hasDueDate = State(
            initialValue:
                item.fields.dueAt != nil
        )

        _hasReminder = State(
            initialValue:
                item.fields.reminderAt != nil
        )
    }

    private var invalid: Bool {
        fields.title
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            .isEmpty

        || fields.title.count > 200
        || fields.notes.count > 4000
        || fields.message.count > 500

        || (
            fields.kind == .event
                && (
                    fields.endAt
                        ?? .distantPast
                )
                <= (
                    fields.startAt
                        ?? .distantFuture
                )
        )
    }

    var body: some View {
        NavigationStack {

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                AgendaSection(
                    "\(fields.kind.title) details"
                ) {
                    TextField(
                        "Title",
                        text: $fields.title
                    )

                    TextField(
                        "Notes",
                        text: $fields.notes,
                        axis: .vertical
                    )
                    .lineLimit(3...8)
                }

                if fields.kind == .event {
                    AgendaSection("Time") {

                        DatePicker(
                            "Starts",
                            selection:
                                dateBinding(
                                    \.startAt
                                )
                        )

                        DatePicker(
                            "Ends",
                            selection:
                                dateBinding(
                                    \.endAt
                                )
                        )
                    }
                }

                if fields.kind == .task {
                    AgendaSection {

                        Toggle(
                            "Due date",
                            isOn: $hasDueDate
                        )

                        if hasDueDate {
                            DatePicker(
                                "Due",
                                selection:
                                    dateBinding(
                                        \.dueAt
                                    )
                            )
                        }

                        Toggle(
                            "Completed",
                            isOn:
                                $fields.completed
                        )
                    }
                }

                AgendaSection(
                    "Conversational reminder",
                    footer: "Repeating check-ins follow this timezone. Use chat to ask for a different schedule. Enable reminder notifications in Calendar or To-do for delivery with the app closed."
                ) {

                    if fields.kind != .reminder {
                        Toggle(
                            "Remind me",
                            isOn: $hasReminder
                        )
                    }

                    if hasReminder
                        || fields.kind == .reminder {

                        DatePicker(
                            "First reminder",
                            selection:
                                dateBinding(
                                    \.reminderAt
                                )
                        )

                        Picker(
                            "Check-in frequency",
                            selection:
                                $fields.repeat
                        ) {
                            ForEach(
                                AgendaRepeat.allCases
                            ) { value in
                                Text(value.title)
                                    .tag(value)
                            }
                        }

                        TextField(
                            "Message (optional)",
                            text:
                                $fields.message,
                            axis: .vertical
                        )

                        if fields.kind == .reminder {
                            Toggle(
                                "Paused",
                                isOn:
                                    $fields.completed
                            )
                        }
                    }

                    Text(
                        "Timezone: \(fields.timezone)"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                }

                if let error = store.error {
                    AgendaSection {
                        Label(
                            error,
                            systemImage:
                                "exclamationmark.triangle"
                        )
                        .foregroundStyle(.red)
                    }
                }

                if item.version > 0 {
                    AgendaSection(
                        footer: fields.kind == .event
                            ? "Apple Calendar export creates a separate copy of the saved event. Later edits in Makima do not update that copy."
                            : nil
                    ) {

                        Button(
                            "Delete \(fields.kind.title.lowercased())",
                            role: .destructive
                        ) {
                            confirmDelete = true
                        }

                    }
                }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .softTopEdge()
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(
                item.version == 0
                    ? "New \(fields.kind.title.lowercased())"
                    : "Edit \(fields.kind.title.lowercased())"
            )
            .navigationBarTitleDisplayMode(
                .inline
            )
            .toolbar {

                ToolbarItem(
                    placement:
                        .cancellationAction
                ) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(store.isSaving)
                }

                ToolbarItem(
                    placement:
                        .confirmationAction
                ) {
                    Button {
                        Task {
                            var changed = item

                            changed.fields =
                                fields

                            if !hasDueDate {
                                changed.fields
                                    .dueAt = nil
                            }

                            if !hasReminder
                                && fields.kind
                                    != .reminder {

                                changed.fields
                                    .reminderAt = nil

                                changed.fields
                                    .repeat = .none
                            }

                            if await store.save(
                                changed
                            ) {
                                dismiss()
                            }
                        }

                    } label: {

                        if store.isSaving {
                            ProgressView()

                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(
                        invalid
                            || store.isSaving
                            || store.isRefreshing
                    )
                }
            }
            .interactiveDismissDisabled(
                store.isSaving
            )
            .confirmationDialog(
                "Delete this \(fields.kind.title.lowercased()) and stop its reminders?",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {

                Button(
                    "Delete",
                    role: .destructive
                ) {
                    Task {
                        if await store.save(
                            item,
                            delete: true
                        ) {
                            dismiss()
                        }
                    }
                }
            }
            .onChange(of: hasDueDate) {
                if hasDueDate
                    && fields.dueAt == nil {

                    fields.dueAt =
                        .now
                        .addingTimeInterval(
                            3600
                        )
                }
            }
            .onChange(of: hasReminder) {
                if hasReminder
                    && fields.reminderAt == nil {

                    fields.reminderAt =
                        .now
                        .addingTimeInterval(
                            3600
                        )
                }
            }
        }
    }

    private func dateBinding(
        _ key:
            WritableKeyPath<
                AgendaFields,
                Date?
            >
    ) -> Binding<Date> {

        Binding(
            get: {
                fields[keyPath: key]
                    ?? .now
            },
            set: {
                fields[keyPath: key] = $0
            }
        )
    }
}

// MARK: - Grouped scroll content

/// Preserve inset-grouped rows without introducing another scroll view.
private struct AgendaSection<Content: View>: View {
    private let title: String?
    private let footer: String?
    private let content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 16)
                    .accessibilityAddTraits(.isHeader)
            }
            rows
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var rows: some View {
        if #available(iOS 18.0, *) {
            Group(subviews: content) { subviews in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(subviews) { subview in
                        if subview.id != subviews.first?.id {
                            Divider().padding(.leading, 16)
                        }
                        subview
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 16) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
    }
}

/// ScrollView exposes the refresh action, but does not always install a pull-to-refresh control.
private struct AgendaRefreshControl: UIViewRepresentable {
    @Environment(\.refresh) private var refresh

    func makeUIView(context: Context) -> RefreshProbe {
        RefreshProbe()
    }

    func updateUIView(_ view: RefreshProbe, context: Context) {
        view.action = refresh
        view.attachIfNeeded()
    }

    static func dismantleUIView(_ view: RefreshProbe, coordinator: ()) {
        view.detach()
    }

    final class RefreshProbe: UIView {
        var action: RefreshAction?
        private weak var scrollView: UIScrollView?
        private let control = UIRefreshControl()
        private var refreshTask: Task<Void, Never>?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            control.addTarget(self, action: #selector(refreshContent), for: .valueChanged)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            attachIfNeeded()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { attachIfNeeded() }
        }

        func attachIfNeeded() {
            guard action != nil else { return }
            var ancestor = superview
            while let current = ancestor {
                if let scroll = current as? UIScrollView {
                    // Leave an existing system refresh control alone.
                    if scroll.refreshControl == nil {
                        scroll.refreshControl = control
                        scrollView = scroll
                    }
                    return
                }
                ancestor = current.superview
            }
        }

        func detach() {
            refreshTask?.cancel()
            if scrollView?.refreshControl === control { scrollView?.refreshControl = nil }
        }

        @objc private func refreshContent() {
            guard refreshTask == nil else { return }
            refreshTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    control.endRefreshing()
                    refreshTask = nil
                }
                await action?()
            }
        }
    }
}
