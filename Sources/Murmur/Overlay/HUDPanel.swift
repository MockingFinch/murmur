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
        model.onModeChange = { [weak self] oldMode, newMode in
            self?.update(from: oldMode, to: newMode)
        }
    }

    private func update(from oldMode: HUDModel.Mode?, to newMode: HUDModel.Mode?) {
        if let newMode {
            hiding?.cancel()
            hiding = nil
            // Re-place whenever the panel was hidden OR a fresh session starts
            // while an old result was still fading out on another display.
            let startingSession = (oldMode == nil || oldMode?.isResult == true) && !newMode.isResult
            if !panel.isVisible || startingSession {
                place()
            }
            if !panel.isVisible {
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

    /// Centered horizontally on the screen holding the focused window (falling
    /// back to the pointer's screen, then main), at the top or bottom edge.
    private func place() {
        let mouse = NSEvent.mouseLocation
        let pointerScreen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let screen = TextBridge.focusedWindowScreen() ?? pointerScreen ?? NSScreen.main ?? NSScreen.screens.first
        guard let area = screen?.visibleFrame else { return }
        let size = HUDView.canvas
        let y: CGFloat = AppSettings.shared.hudPosition == .top
            ? area.maxY - size.height - 6
            : area.minY + 6
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: y, width: size.width, height: size.height), display: false)
    }
}
