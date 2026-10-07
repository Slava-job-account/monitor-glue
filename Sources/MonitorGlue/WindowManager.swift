import AppKit
import ApplicationServices
import Darwin

/// A live window read from the Accessibility API.
struct LiveWindow {
    var element: AXUIElement
    var appBundleID: String
    var appName: String
    var title: String
    var index: Int          // Index within the app's window list.
    var frame: CGRect       // AX global coords (top-left origin).
    var identity: WindowIdentity
    var isOnScreen: Bool = true
}

/// Window numbers survive Space switches, but may be reused after the owning app exits.
struct WindowIdentity: Codable, Hashable {
    var pid: pid_t
    var launchedAt: TimeInterval
    var number: CGWindowID

    var key: String { "\(pid):\(launchedAt):\(number)" }
    var isRunning: Bool { NSRunningApplication(processIdentifier: pid)?.launchDate?.timeIntervalSince1970 == launchedAt }
}

/// Reads and repositions other applications' windows via the Accessibility API.
/// All coordinates are AX global (top-left origin), matching `CGDisplayBounds`.
enum WindowManager {

    // AXWindows may omit inactive Spaces. Retain references learned on earlier visits;
    // invalidate them when their window closes or the owning process exits.
    private static var knownWindows: [WindowIdentity: LiveWindow] = [:]
    private typealias WindowNumber = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let windowNumber: WindowNumber? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else {
            Log.write("window tracking unavailable — macOS window identity API is missing")
            return nil
        }
        return unsafeBitCast(symbol, to: WindowNumber.self)
    }()

    // MARK: Enumeration

    static func currentWindows() -> [LiveWindow] {
        guard AXIsProcessTrusted() else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // Per-bundle counter so indices are dense and unique even when an app has several
        // processes sharing one bundle ID (Chrome profiles) or windows were filtered out.
        // Capture and restore both read indices from here, so they always agree.
        var nextIndex: [String: Int] = [:]

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  app.processIdentifier != ownPID,
                  let bundleID = app.bundleIdentifier,
                  let launchedAt = app.launchDate?.timeIntervalSince1970 else { continue }

            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            // Right after a display change apps are busy re-laying out and answer AX slowly.
            // Without a short timeout one such app blocks this whole pass on the main thread;
            // with it, a busy app is skipped and picked up by the next retry. Keep it around a second:
            // a first AX contact with an app needs a few hundred ms, so a tighter cap returns
            // no windows at all.
            AXUIElementSetMessagingTimeout(appElement, 1.0)
            guard let windows = copyValue(appElement, kAXWindowsAttribute) as? [AXUIElement] else { continue }

            for win in windows {
                guard let frame = frame(of: win) else { continue }
                // Only real, movable windows: standard subrole, not minimized, non-trivial size.
                // Filters out Finder desktop windows, palettes, PiP slivers, etc.
                guard (copyValue(win, kAXSubroleAttribute) as? String) == (kAXStandardWindowSubrole as String)
                else { continue }
                if let minimized = copyValue(win, kAXMinimizedAttribute) as? Bool, minimized { continue }
                guard frame.width >= 100, frame.height >= 100 else { continue }
                let title = (copyValue(win, kAXTitleAttribute) as? String) ?? ""
                let idx = nextIndex[bundleID, default: 0]
                nextIndex[bundleID] = idx + 1
                var number: CGWindowID = 0
                guard windowNumber?(win, &number) == .success, number != 0 else { continue }
                let identity = WindowIdentity(pid: app.processIdentifier, launchedAt: launchedAt, number: number)
                knownWindows[identity] = LiveWindow(
                    element: win,
                    appBundleID: bundleID,
                    appName: app.localizedName ?? bundleID,
                    title: title,
                    index: idx,
                    frame: frame,
                    identity: identity
                )
            }
        }
        let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let visibleIDs = Set(visible.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
        var windows: [LiveWindow] = []
        for (identity, var window) in knownWindows {
            var role: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(window.element, kAXRoleAttribute as CFString, &role)
            guard identity.isRunning, error != .invalidUIElement else {
                knownWindows.removeValue(forKey: identity)
                continue
            }
            guard let frame = frame(of: window.element) else { continue }
            // Minimized and fullscreen windows remain cached for when they return to normal.
            guard (copyValue(window.element, "AXFullScreen") as? Bool) != true else { continue }
            guard (copyValue(window.element, kAXMinimizedAttribute) as? Bool) != true else { continue }
            window.frame = frame
            window.title = (copyValue(window.element, kAXTitleAttribute) as? String) ?? window.title
            window.isOnScreen = visibleIDs.contains(identity.number)
            windows.append(window)
        }
        return windows
    }

    // MARK: Frame read/write

    static func frame(of window: AXUIElement) -> CGRect? {
        guard let posValue = copyValue(window, kAXPositionAttribute),
              let sizeValue = copyValue(window, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// Move + resize a window to an exact frame.
    ///
    /// A single position-then-size pass is not enough when the window is coming from a
    /// smaller display: macOS clamps the new size to the screen the window still occupies
    /// (e.g. a 2560-wide window arrives clamped to 1998 = the built-in's right edge). Moving
    /// it first, then re-applying the size once it is actually on the target display, lets the
    /// full size take. Apply position and size repeatedly and verify, since some apps also
    /// snap the origin when resized.
    @discardableResult
    static func setFrame(_ window: AXUIElement, _ frame: CGRect) -> Bool {
        for _ in 0..<3 {
            apply(window, position: frame.origin)
            apply(window, size: frame.size)
            apply(window, position: frame.origin)
            apply(window, size: frame.size)
            if let now = self.frame(of: window), now.matches(frame) { return true }
        }
        return self.frame(of: window)?.matches(frame) ?? false
    }

    private static func apply(_ window: AXUIElement, position: CGPoint) {
        var p = position
        guard let v = AXValueCreate(.cgPoint, &p) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v)
    }

    private static func apply(_ window: AXUIElement, size: CGSize) {
        var s = size
        guard let v = AXValueCreate(.cgSize, &s) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v)
    }

    // MARK: Display mapping

    /// Which live display a window sits on, by its center point. nil if off all displays.
    static func display(for window: LiveWindow, in displays: [LiveDisplay]) -> LiveDisplay? {
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        return displays.first { $0.bounds.contains(center) }
    }

    // MARK: Helpers

    private static func copyValue(_ element: AXUIElement, _ attr: String) -> AnyObject? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
        return err == .success ? value : nil
    }
}

extension CGRect {
    /// Frame comparison with a small tolerance — AX rounds, and some apps snap by a pixel.
    func matches(_ other: CGRect, tolerance: CGFloat = 3) -> Bool {
        abs(origin.x - other.origin.x) < tolerance && abs(origin.y - other.origin.y) < tolerance &&
        abs(width - other.width) < tolerance && abs(height - other.height) < tolerance
    }
}
