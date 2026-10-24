import AppKit
import WebKit

class PomodoroPanel: NSPanel {
    override var canBecomeKey: Bool {
        return true
    }
    override var canBecomeMain: Bool {
        return true
    }
    
    /// When pinned, key the panel before dispatching clicks so WebView controls work on first click.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown,
           let wc = windowController as? WindowController,
           wc.isPinned,
           (!isKeyWindow || !NSApp.isActive) {
            wc.activatePanelForPinnedInteraction()
        }
        super.sendEvent(event)
    }
    
    // Explicitly handle standard edit shortcuts to ensure they work in the WKWebView
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            let key = event.charactersIgnoringModifiers?.lowercased()
            switch key {
            case "x":
                if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) { return true }
            case "c":
                if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) { return true }
            case "v":
                if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) { return true }
            case "a":
                if NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self) { return true }
            case "z":
                if event.modifierFlags.contains(.shift) {
                    if NSApp.sendAction(#selector(UndoManager.redo), to: nil, from: self) { return true }
                } else {
                    if NSApp.sendAction(#selector(UndoManager.undo), to: nil, from: self) { return true }
                }
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Invisible hit target for pinned-window dragging via `performDrag` (no Accessibility permission required).
private final class PinnedDragHandleView: NSView {
    weak var windowController: WindowController?
    private let handleWidth: CGFloat = 112
    private let handleHeight: CGFloat = 32
    private var showTooltipTimer: Timer?
    private let tooltipShowDelay: TimeInterval = 0.7
    
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil))
    }
    
    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }
    
    override func mouseEntered(with event: NSEvent) {
        showTooltipTimer?.invalidate()
        showTooltipTimer = Timer.scheduledTimer(withTimeInterval: tooltipShowDelay, repeats: false) { [weak self] _ in
            self?.windowController?.showDragHandleTooltip()
        }
    }
    
    override func mouseExited(with event: NSEvent) {
        showTooltipTimer?.invalidate()
        showTooltipTimer = nil
        windowController?.hideDragHandleTooltip()
    }
    
    override func mouseDown(with event: NSEvent) {
        showTooltipTimer?.invalidate()
        showTooltipTimer = nil
        windowController?.hideDragHandleTooltip()
        guard let window = window else { return }
        windowController?.activatePanelForPinnedInteraction()
        window.performDrag(with: event)
        windowController?.notePinnedWindowDragCompleted()
    }
    
    func layout(in contentBounds: NSRect) {
        let x = (contentBounds.width - handleWidth) / 2
        let y = contentBounds.height - handleHeight - 12
        frame = NSRect(x: x, y: y, width: handleWidth, height: handleHeight)
    }
}

class WindowController: NSWindowController {
    var panel: NSPanel!
    var webView: WKWebView!
    var bridge: Bridge!
    weak var statusBarController: StatusBarController?
    private var eventMonitor: Any?
    private var pinnedDragHandleView: PinnedDragHandleView?
    /// True after the user drags the pinned window this session; cleared on unpin or relaunch.
    private var sessionPinnedPositionActive = false
    
    /// Pin state - when true, the window stays visible even when clicking outside
    private(set) var isPinned: Bool = false {
        didSet {
            if !isPinned {
                sessionPinnedPositionActive = false
            }
            updatePinnedState()
        }
    }

    init() {
        // Use PomodoroPanel to allow it to become key (necessary for text input)
        let panel = PomodoroPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 520),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        self.panel = panel
        super.init(window: panel)
        
        // Restore pinned state from UserDefaults
        isPinned = UserDefaults.standard.bool(forKey: "windowPinned")
        
        setupPanel()
        setupWebView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupPanel() {
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        
        // Apply initial collection behavior and activation policy from pinned state
        updatePanelCollectionBehavior()
        updatePanelActivationBehavior()
        
        // Native border radius enforcement
        if let contentView = panel.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = 28
            contentView.layer?.masksToBounds = true
        }
        
        // Remove window background completely
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
    }
    
    private func updatePanelCollectionBehavior() {
        if isPinned {
            // When pinned: stay visible across spaces, don't hide, float above other windows
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.level = .floating
        } else {
            // When unpinned: transient behavior (default menu bar app style)
            panel.collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle]
            panel.level = .statusBar
        }
    }
    
    private func updatePanelActivationBehavior() {
        if isPinned {
            // Pinned = floating utility: accept first click on controls without extra activation step
            panel.styleMask.remove(.nonactivatingPanel)
            panel.becomesKeyOnlyIfNeeded = false
        } else {
            // Unpinned = menu bar popover: avoid stealing focus from the frontmost app
            panel.styleMask.insert(.nonactivatingPanel)
            panel.becomesKeyOnlyIfNeeded = true
        }
    }
    
    private func updatePinnedState() {
        // Update panel behavior
        updatePanelCollectionBehavior()
        updatePanelActivationBehavior()
        
        // Persist the state
        UserDefaults.standard.set(isPinned, forKey: "windowPinned")
        UserDefaults.standard.synchronize()
        
        // Update event monitoring
        if isPinned {
            stopMonitoring()
        } else if panel.isVisible {
            startMonitoring()
        }
        
        // Notify JS about the state change
        bridge?.sendToJS(action: "pinnedStateChanged", data: ["isPinned": isPinned])
        
        updatePinnedDragHandle()
        
        print("WindowController: Pinned state changed to \(isPinned)")
    }
    
    /// Sets the pinned state
    func setPinned(_ pinned: Bool) {
        isPinned = pinned
    }
    
    /// Toggles the pinned state
    func togglePinned() {
        isPinned.toggle()
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        bridge = Bridge(windowController: self)
        config.userContentController.add(bridge, name: "native")
        
        // Register custom scheme handler to fix CORS issues with local files
        config.setURLSchemeHandler(AppSchemeHandler(), forURLScheme: "app")
        
        // Use a safer configuration
        let preferences = WKPreferences()
        preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.preferences = preferences
        
        webView = WKWebView(frame: panel.contentView!.bounds, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.autoresizingMask = [.width, .height]
        
        panel.contentView?.addSubview(webView)
        updatePinnedDragHandle()
        
        // Improved Dev Mode detection:
        // 1. Check if we're running in Xcode (no bundle identifier)
        // 2. Or if DEBUG flag is explicitly set
        let isRunningInXcode = Bundle.main.bundleIdentifier == nil
        
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif

        if isRunningInXcode || isDebug {
            if let url = URL(string: "http://localhost:5173") {
                print("WindowController: [DEV MODE] Loading from localhost:5173")
                let request = URLRequest(url: url)
                webView.load(request)
                return
            }
        }
        
        // Production mode fallback
        print("WindowController: [PROD MODE] Loading from app://localhost/index.html")
        let version = Int(Date().timeIntervalSince1970)
        if let url = URL(string: "app://localhost/index.html?v=\(version)") {
            webView.load(URLRequest(url: url))
        }
    }

    func show(relativeTo rect: NSRect) {
        panel.alphaValue = 1.0
        let shouldAnchorToMenuBar = !isPinned
            || !panel.isVisible
            || (isPinned && !sessionPinnedPositionActive)
        if shouldAnchorToMenuBar {
            let x = rect.origin.x + (rect.width / 2) - (panel.frame.width / 2)
            let y = rect.origin.y - panel.frame.height - 5
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updatePinnedDragHandle()
        
        // Only start monitoring if not pinned
        if !isPinned {
            startMonitoring()
        }
        
        // Send current pinned state to JS
        bridge?.sendToJS(action: "pinnedStateChanged", data: ["isPinned": isPinned])
    }

    func hide() {
        // If pinned, don't actually hide - just lose focus
        if isPinned {
            return
        }
        
        // Expert Fix: If a timer is running, we don't want to fully 'orderOut' 
        // as macOS may aggressively throttle the WKWebView process.
        // Instead, we make it invisible but technically 'on-screen'.
        if let appDelegate = NSApp.delegate as? AppDelegate, 
           let pomodoroStore = UserDefaults.standard.string(forKey: "pomodoroState"),
           pomodoroStore.contains("\"status\":\"running\"") {
            panel.alphaValue = 0.0
            // We still want to stop monitoring clicks to avoid accidental triggers
            stopMonitoring()
            print("WindowController: Hiding via alphaValue to maintain WebView vitality")
        } else {
            panel.orderOut(nil)
            stopMonitoring()
        }
        
        bridge.sendToJS(action: "windowHidden", data: [:])
    }
    
    /// Force hide the window even if pinned (for explicit close actions)
    func forceHide() {
        if let appDelegate = NSApp.delegate as? AppDelegate, 
           let pomodoroStore = UserDefaults.standard.string(forKey: "pomodoroState"),
           pomodoroStore.contains("\"status\":\"running\"") {
            panel.alphaValue = 0.0
            print("WindowController: Force hiding via alphaValue to maintain WebView vitality")
        } else {
            panel.orderOut(nil)
            panel.alphaValue = 1.0 // Reset alpha
        }
        stopMonitoring()
        bridge.sendToJS(action: "windowHidden", data: [:])
    }
    
    /// Brings the window forward without hiding it when it is already open.
    func reveal(relativeTo rect: NSRect) {
        if panel.isVisible && panel.alphaValue > 0 {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            panel.alphaValue = 1.0
            show(relativeTo: rect)
        }
    }

    func toggle(relativeTo rect: NSRect) {
        if panel.isVisible && panel.alphaValue > 0 {
            // If pinned, toggling should still hide the window
            if isPinned {
                forceHide()
            } else {
                hide()
            }
        } else {
            // Reset alpha if it was hidden via alpha
            panel.alphaValue = 1.0
            show(relativeTo: rect)
        }
    }

    private func startMonitoring() {
        // Don't monitor clicks if pinned
        guard !isPinned else { return }
        
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self else { return }
            
            // Don't hide if pinned
            if self.isPinned { return }
            
            // Check if the click is inside the panel
            let clickLocation = event.locationInWindow
            let panelFrame = self.panel.frame
            
            // Convert screen coordinates properly
            let clickScreenLocation = NSEvent.mouseLocation
            if !panelFrame.contains(clickScreenLocation) {
                self.hide()
            }
        }
        
        // Remove localEventMonitor for Space/Escape. 
        // These are now handled in React (App.tsx) to avoid interfering with text inputs.
    }

    private func stopMonitoring() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
    
    // MARK: - Pinned interaction
    
    func activatePanelForPinnedInteraction() {
        guard isPinned, panel.isVisible, panel.alphaValue > 0 else { return }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // MARK: - Pinned window drag
    
    /// Called from Bridge when JS requests drag; native handle uses `performDrag` directly.
    func beginPinnedDrag() {
        // Drag is handled by PinnedDragHandleView.mouseDown — kept for bridge compatibility.
    }
    
    func notePinnedWindowDragCompleted() {
        sessionPinnedPositionActive = true
    }
    
    func showDragHandleTooltip() {
        guard isPinned else { return }
        // Position is resolved in JS from the drag-grip element (AppKit→CSS Y flip is unreliable in WKWebView).
        bridge?.sendToJS(action: "dragHandleTooltip", data: ["show": true])
    }
    
    func hideDragHandleTooltip() {
        bridge?.sendToJS(action: "dragHandleTooltip", data: ["show": false])
    }
    
    private func updatePinnedDragHandle() {
        guard let contentView = panel.contentView, webView != nil else { return }
        
        if isPinned {
            if pinnedDragHandleView == nil {
                let handle = PinnedDragHandleView()
                handle.windowController = self
                contentView.addSubview(handle, positioned: .above, relativeTo: webView)
                pinnedDragHandleView = handle
            }
            pinnedDragHandleView?.layout(in: contentView.bounds)
            pinnedDragHandleView?.isHidden = false
        } else {
            pinnedDragHandleView?.isHidden = true
        }
    }
}
