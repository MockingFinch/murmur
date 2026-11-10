import AppKit
import SwiftUI

/// A floating window that never takes focus: the app you dictate into
/// keeps its caret, and clicks pass straight through.
final class HUDPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(origin: .zero, size: HUDView.canvas),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class HUDController {
    private let panel = HUDPanel()
    private let model: HUDModel
    private var hiding: Task<Void, Never>?

    init(model: HUDModel) {
        self.model = model
        let host = NSHostingView(rootView: HUDView(model: model))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: HUDView.canvas)
        panel.contentView = host
        model.onModeChange = { [weak self] mode in self?.update(visible: mode != nil) }
    }

    private func update(visible: Bool) {
        if visible {
            hiding?.cancel()
            hiding = nil
            if !panel.isVisible {
                place()
                panel.orderFrontRegardless()
            }
        } else {
            hiding?.cancel()
            hiding = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000) // let the exit animation finish
                guard !Task.isCancelled, let self, self.model.mode == nil else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    /// Bottom centre of the screen the pointer is on, just above the Dock.
    private func place() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let size = HUDView.canvas
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.minY + 6, width: size.width, height: size.height), display: false)
    }
}
