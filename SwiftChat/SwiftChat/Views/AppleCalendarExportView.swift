import SwiftUI
import EventKit
import EventKitUI

struct AppleCalendarExportView: UIViewControllerRepresentable {

    let item: AgendaItem

    @Environment(\.dismiss)
    private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator {
            dismiss()
        }
    }

    func makeUIViewController(
        context: Context
    ) -> EKEventEditViewController {

        let controller = SoftEdgeEventEditViewController()
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)

        let startDate = item.fields.startAt ?? .now
        let endDate = item.fields.endAt
            ?? startDate.addingTimeInterval(3600)

        event.title = item.fields.title
        event.notes = item.fields.notes
        event.startDate = startDate
        event.endDate = endDate

        if let timeZone = TimeZone(
            identifier: item.fields.timezone
        ) {
            event.timeZone = timeZone
        }

        if let reminder = item.fields.reminderAt,
           item.fields.repeat == .none {

            event.addAlarm(
                EKAlarm(
                    absoluteDate: reminder
                )
            )
        }

        controller.eventStore = store
        controller.event = event
        controller.editViewDelegate = context.coordinator

        return controller
    }

    func updateUIViewController(
        _ controller: EKEventEditViewController,
        context: Context
    ) {
        guard let view = controller.viewIfLoaded else { return }
        applySoftTopEdge(to: view)
    }

    final class Coordinator:
        NSObject,
        EKEventEditViewDelegate {

        private let onComplete: () -> Void

        init(
            onComplete: @escaping () -> Void
        ) {
            self.onComplete = onComplete
        }

        func eventEditViewController(
            _ controller: EKEventEditViewController,
            didCompleteWith action: EKEventEditViewAction
        ) {
            onComplete()
        }
    }
}

/// Keep Apple's editor; configure accessible scroll views after EventKit lays them out.
private final class SoftEdgeEventEditViewController: EKEventEditViewController {
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applySoftTopEdge(to: view)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applySoftTopEdge(to: view)
    }
}

@MainActor
private func applySoftTopEdge(
    to view: UIView
) {
    if #available(iOS 26.0, *) {
        if let scrollView = view as? UIScrollView {
            scrollView.topEdgeEffect.style = .soft
        }

        for subview in view.subviews {
            applySoftTopEdge(
                to: subview
            )
        }
    }
}
