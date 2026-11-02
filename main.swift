import AppKit
import ScreenCaptureKit
import ServiceManagement

// Slow Window Switcher smooths sudden changes in screen brightness.
// It measures the mean light output of each display. When that light jumps, a click-through
// overlay keeps the light at the old level and then fades away, so the glare changes slowly.

/// Converts an 8-bit sRGB channel value to linear light.
let srgbToLinear: [Float] = (0..<256).map { i in
    let c = Float(i) / 255
    return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
}

/// The lowest mean luminance that the app tracks. It keeps the log value finite on a black screen.
let minLuminance: Float = 0.005

@MainActor
enum Settings {
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "enabled") }
    }
    static var fadeSeconds: Double {
        get { UserDefaults.standard.double(forKey: "fadeSeconds") }
        set { UserDefaults.standard.set(newValue, forKey: "fadeSeconds") }
    }
    /// The user's choice. The real login item can differ from it, for example after a rebuild.
    static var startAtLogin: Bool {
        get { UserDefaults.standard.bool(forKey: "startAtLogin") }
        set { UserDefaults.standard.set(newValue, forKey: "startAtLogin") }
    }
}

/// Measures one display and controls the overlay window on that display.
@MainActor
final class DisplaySmoother: NSObject, SCStreamOutput, SCStreamDelegate {
    let displayID: CGDirectDisplayID
    var onStop: (() -> Void)?

    private let framesPerSecond: Int
    private let window: NSWindow
    private let overlay: CALayer
    private var displayLink: CADisplayLink?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "capture")

    // All brightness values are natural logs of mean linear luminance.
    private var actual: Float?   // The real screen content.
    private var shown: Float = 0 // The level that the user sees through the overlay.
    private var velocity: Float = 0

    init(screen: NSScreen) {
        displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        framesPerSecond = max(60, screen.maximumFramesPerSecond)
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // Keep the overlay out of screen shares, so viewers see the normal screen.
        window.sharingType = .none
        window.isReleasedWhenClosed = false
        window.contentView!.wantsLayer = true
        overlay = window.contentView!.layer!
        super.init()
        window.orderFrontRegardless()
        displayLink = screen.displayLink(target: self, selector: #selector(tick(_:)))
        displayLink?.add(to: .main, forMode: .common)
    }

    func start(display: SCDisplay, excluding apps: [SCRunningApplication]) async throws {
        // Exclude this app, so the measurement does not include the overlay.
        let filter = SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = 128
        config.height = max(1, 128 * display.height / display.width)
        // Capture at the full refresh rate, so a change gets to the overlay as soon as possible.
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        window.orderOut(nil)
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: status) == .complete,
              let pixels = sampleBuffer.imageBuffer else { return }
        let luminance = Self.meanLuminance(pixels)
        DispatchQueue.main.async { self.setActual(luminance) }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Capture stopped: \(error.localizedDescription)")
        DispatchQueue.main.async { self.onStop?() }
    }

    private nonisolated static func meanLuminance(_ buffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var sum: Float = 0
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let p = row + x * 4 // BGRA
                sum += 0.0722 * srgbToLinear[Int(p[0])] + 0.7152 * srgbToLinear[Int(p[1])] + 0.2126 * srgbToLinear[Int(p[2])]
            }
        }
        return sum / Float(width * height)
    }

    private func setActual(_ luminance: Float) {
        let value = logf(max(luminance, minLuminance))
        if actual == nil || !Settings.enabled { shown = value }
        actual = value
        // Cover the new frame now. A paused display link can take one more frame to tick.
        applyOverlay(actual: value)
        displayLink?.isPaused = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let actual else { return }
        let dt = Float(min(link.targetTimestamp - link.timestamp, 0.05))
        if Settings.enabled {
            // A critically damped spring eases in and out. It gets 95% of the way in fadeSeconds.
            let omega = 4.74 / Float(Settings.fadeSeconds)
            velocity += (omega * omega * (actual - shown) - 2 * omega * velocity) * dt
            shown += velocity * dt
        }
        if !Settings.enabled || (abs(actual - shown) < 0.002 && abs(velocity) < 0.01) {
            shown = actual
            velocity = 0
            link.isPaused = true
        }
        applyOverlay(actual: actual)
    }

    private func applyOverlay(actual: Float) {
        // WindowServer blends gamma-encoded values, so the math uses encoded values (approx. gamma 2.2).
        let real = powf(expf(actual), 1 / 2.2)
        let wanted = powf(expf(shown), 1 / 2.2)
        let color: CGColor
        if wanted < real {
            // Black at alpha a multiplies each encoded value by (1 - a).
            color = CGColor(gray: 0, alpha: CGFloat(1 - wanted / real))
        } else {
            // White at alpha a moves each encoded value v to v + (1 - v) * a.
            color = CGColor(gray: 1, alpha: CGFloat(min(1, (wanted - real) / max(1 - real, 0.001))))
        }
        guard color != overlay.backgroundColor else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.backgroundColor = color
        CATransaction.commit()
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "Starting", action: nil, keyEquivalent: "")
    private var enabledItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var fadeItem: NSMenuItem!
    private var fadeItems: [NSMenuItem] = []
    private var smoothers: [DisplaySmoother] = []
    private var generation = 0
    // The last known states. The app prompts only when a state changes to false.
    private var screenAccess: Bool?
    private var loginEnabled: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["enabled": true, "fadeSeconds": 3, "startAtLogin": true])
        buildMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(restart),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        restart()
        checkHealth()
        Timer.scheduledTimer(timeInterval: 60, target: self, selector: #selector(checkHealth), userInfo: nil, repeats: true)
    }

    /// Prompts the user when the Screen Recording permission or the login item turns off.
    @objc private func checkHealth() {
        if !CGPreflightScreenCaptureAccess() { screenAccessChanged(granted: false) }
        let enabled = SMAppService.mainApp.status == .enabled
        let turnedOff = loginEnabled != false && !enabled
        loginEnabled = enabled
        if turnedOff && Settings.startAtLogin { promptForLogin() }
        updateMenu()
    }

    private func screenAccessChanged(granted: Bool) {
        let wasGranted = screenAccess
        screenAccess = granted
        guard !granted else { return }
        statusLine.title = "Needs Screen Recording permission"
        if wasGranted != false { promptForScreenRecording() }
    }

    private func promptForScreenRecording() {
        let alert = NSAlert()
        alert.messageText = "SlowWindowSwitcher needs Screen Recording permission"
        alert.informativeText = "The app uses it to measure screen brightness. Turn on SlowWindowSwitcher in System Settings, then reopen the app."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // This call adds the app to the list in System Settings.
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    private func promptForLogin() {
        let alert = NSAlert()
        alert.messageText = "SlowWindowSwitcher will not start at login"
        alert.informativeText = "The login item is off. This can occur after a rebuild or a change in System Settings."
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Keep Off")
        NSApp.activate()
        setLoginItem(alert.runModal() == .alertFirstButtonReturn)
    }

    @objc private func restart() {
        generation += 1
        let current = generation
        smoothers.forEach { $0.stop() }
        smoothers = []
        guard CGPreflightScreenCaptureAccess() else {
            screenAccessChanged(granted: false)
            return
        }
        // Create the overlay windows first, so this app is in the shareable content and can be excluded.
        let created = NSScreen.screens.map { DisplaySmoother(screen: $0) }
        smoothers = created
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                let me = content.applications.filter { $0.processID == getpid() }
                for smoother in created {
                    guard current == generation,
                          let display = content.displays.first(where: { $0.displayID == smoother.displayID }) else { continue }
                    smoother.onStop = { [weak self] in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.restart() }
                    }
                    try await smoother.start(display: display, excluding: me)
                }
                // A newer restart replaced these smoothers while this one was in progress.
                guard current == generation else { created.forEach { $0.stop() }; return }
                screenAccessChanged(granted: true)
                statusLine.title = "Smoothing \(created.count) display(s)"
            } catch let error as SCStreamError where error.code == .userDeclined {
                // The permission can be gone even when the preflight check still returns true.
                screenAccessChanged(granted: false)
            } catch {
                statusLine.title = "Capture failed: \(error.localizedDescription)"
            }
        }
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Slow Window Switcher")
        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        enabledItem = menu.addItem(withTitle: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        let fadeMenu = NSMenu()
        for seconds in [0.5, 1, 1.5, 2, 3, 5, 7, 10] {
            let item = fadeMenu.addItem(withTitle: "\(seconds.formatted()) s", action: #selector(setFade(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            fadeItems.append(item)
        }
        fadeItem = menu.addItem(withTitle: "Fade Duration", action: nil, keyEquivalent: "")
        menu.setSubmenu(fadeMenu, for: fadeItem)
        loginItem = menu.addItem(withTitle: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.delegate = self
        statusItem.menu = menu
        updateMenu()
    }

    // The user can change login items in System Settings, so read the status each time the menu opens.
    func menuWillOpen(_ menu: NSMenu) {
        updateMenu()
    }

    private func updateMenu() {
        enabledItem.state = Settings.enabled ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        fadeItem.title = "Fade Duration (\(Settings.fadeSeconds.formatted())s)"
        for item in fadeItems {
            item.state = item.representedObject as? Double == Settings.fadeSeconds ? .on : .off
        }
    }

    @objc private func toggleEnabled() {
        Settings.enabled.toggle()
        updateMenu()
    }

    @objc private func toggleLogin() {
        setLoginItem(SMAppService.mainApp.status != .enabled)
    }

    private func setLoginItem(_ on: Bool) {
        Settings.startAtLogin = on
        let service = SMAppService.mainApp
        do {
            if on && service.status != .enabled {
                try service.register()
            } else if !on && service.status == .enabled {
                try service.unregister()
            }
        } catch {
            NSApp.activate()
            NSAlert(error: error).runModal()
        }
        // macOS can hold a new login item until the user approves it in System Settings.
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        loginEnabled = service.status == .enabled
        updateMenu()
    }

    @objc private func setFade(_ sender: NSMenuItem) {
        Settings.fadeSeconds = sender.representedObject as! Double
        updateMenu()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = AppController()
    app.delegate = controller
    app.run()
}
