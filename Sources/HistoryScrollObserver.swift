import SwiftUI
import AppKit

// LazyVStack reicht ihre Geometrie-Präferenzen auf macOS nicht zuverlässig
// weiter. Für das automatische Folgen zählt die echte sichtbare Scrollfläche.
struct HistoryScrollObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onChange = onChange
        DispatchQueue.main.async { view.bind() }
    }

    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.unbind() }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private weak var scrollView: NSScrollView?
        private var observation: NSObjectProtocol?
        private var previouslyPostedChanges = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { self.bind() }
        }

        func bind() {
            guard let enclosing = enclosingScrollView else { unbind(); return }
            if scrollView !== enclosing {
                unbind()
                scrollView = enclosing
                previouslyPostedChanges = enclosing.contentView.postsBoundsChangedNotifications
                enclosing.contentView.postsBoundsChangedNotifications = true
                observation = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: enclosing.contentView, queue: .main
                ) { [weak self] _ in
                    DispatchQueue.main.async { self?.report() }
                }
            }
            report()
        }

        func unbind() {
            if let observation { NotificationCenter.default.removeObserver(observation) }
            observation = nil
            scrollView?.contentView.postsBoundsChangedNotifications = previouslyPostedChanges
            scrollView = nil
        }

        private func report() {
            guard let scrollView, let document = scrollView.documentView else { return }
            let visible = scrollView.documentVisibleRect
            let remaining = document.isFlipped ? document.bounds.maxY - visible.maxY
                : visible.minY - document.bounds.minY
            onChange?(remaining <= 24)
        }
    }
}
