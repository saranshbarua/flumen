import AppKit

class StatusBarController {
    private var statusBar: NSStatusBar
    private var statusItem: NSStatusItem
    private var windowController: WindowController
    private var nativeTimer: DispatchSourceTimer?

    init(windowController: WindowController) {
        self.windowController = windowController
        self.statusBar = NSStatusBar.system
        self.statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        
        setupButton()
    }

    private func setupButton() {
        if let button = statusItem.button {
            button.image = Self.flumenMenuBarImage()
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.action = #selector(handleAction(_:))
            button.target = self
            // Support both left and right clicks
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    /// Colored Flumen mark for the menu bar (not a template — keeps brand red).
    private static func flumenMenuBarImage() -> NSImage {
        let pointSize = NSSize(width: 24, height: 24)
        // Use Bundle.main only — packaged apps copy icons into Contents/Resources.
        // Do not touch Bundle.module: it fatal-errors when Flumen_Flumen.bundle
        // is absent from the .app (SPM resource accessor assertion).
        for name in ["MenuBarIcon@2x", "MenuBarIcon"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                image.size = pointSize
                image.isTemplate = false
                image.accessibilityDescription = "Flumen"
                return image
            }
        }
        return NSImage(systemSymbolName: "timer", accessibilityDescription: "Flumen")!
    }

    @objc func handleAction(_ sender: Any?) {
        let event = NSApp.currentEvent
        
        if event?.type == .rightMouseUp {
            showContextMenu()
        } else {
            if let button = statusItem.button {
                let rect = button.window?.convertToScreen(button.frame) ?? .zero
                windowController.toggle(relativeTo: rect)
            }
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        
        menu.addItem(NSMenuItem(title: "Start / Pause", action: #selector(menuStartPause), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Skip", action: #selector(menuSkip), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reset", action: #selector(menuReset), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        
        // Pin/Unpin option
        let isPinned = windowController.isPinned
        let pinItem = NSMenuItem(
            title: isPinned ? "Unpin from Screen" : "Pin to Screen",
            action: #selector(menuTogglePin),
            keyEquivalent: "p"
        )
        pinItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(pinItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "About Flumen", action: #selector(menuAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Check for Updates...", action: #selector(menuUpdate), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(menuQuit), keyEquivalent: "q"))
        
        for item in menu.items {
            item.target = self
        }
        
        statusItem.menu = menu
        statusItem.button?.performClick(nil) // Trigger the menu
        statusItem.menu = nil // Reset so next left click works as before
    }

    @objc func menuStartPause() {
        windowController.bridge.sendToJS(action: "menuAction", data: ["type": "toggle"])
    }

    @objc func menuSkip() {
        windowController.bridge.sendToJS(action: "menuAction", data: ["type": "skip"])
    }

    @objc func menuReset() {
        windowController.bridge.sendToJS(action: "menuAction", data: ["type": "reset"])
    }
    
    @objc func menuTogglePin() {
        windowController.togglePinned()
    }

    @objc func menuAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc func menuUpdate() {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.updaterController?.checkForUpdates(nil)
        }
    }

    @objc func menuQuit() {
        NSApplication.shared.terminate(nil)
    }

    @objc func toggleWindow(_ sender: Any?) {
        if let button = statusItem.button {
            let rect = button.window?.convertToScreen(button.frame) ?? .zero
            windowController.toggle(relativeTo: rect)
        }
    }
    
    func revealWindow() {
        windowController.reveal(relativeTo: getAnchorRect())
    }

    func getAnchorRect() -> NSRect {
        if let button = statusItem.button {
            return button.window?.convertToScreen(button.frame) ?? .zero
        }
        return .zero
    }

    /// Shows a short confirmation in the menu bar, unless a countdown owns the title.
    func flashTitle(_ title: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.nativeTimer == nil, let button = self.statusItem.button else { return }
            let previous = button.title
            button.title = title
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                if self?.statusItem.button?.title == title {
                    self?.statusItem.button?.title = previous
                }
            }
        }
    }

    func updateTitle(_ title: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.button?.title = title
        }
    }

    func startCountdown(endTime: Date) {
        stopCountdown()
        
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            
            let now = Date()
            let remaining = Int(ceil(endTime.timeIntervalSince(now)))
            
            if remaining <= 0 {
                self.updateTitle("00:00")
                self.stopCountdown()
                return
            }
            
            let mins = remaining / 60
            let secs = remaining % 60
            let timeStr = String(format: "%02d:%02d", mins, secs)
            self.updateTitle(timeStr)
        }
        
        self.nativeTimer = timer
        timer.resume()
        print("StatusBarController: Started native countdown timer")
    }

    func stopCountdown() {
        if let timer = nativeTimer {
            timer.cancel()
            nativeTimer = nil
            print("StatusBarController: Stopped native countdown timer")
        }
    }
}
 
