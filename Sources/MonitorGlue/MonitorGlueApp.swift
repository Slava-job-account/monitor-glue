import SwiftUI
import AppKit

@main
struct MonitorGlueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared
    @StateObject private var permissions = Permissions.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
                .environmentObject(permissions)
        } label: {
            Image(nsImage: AppGlyph.menuBarTemplate())
        }
        .menuBarExtraStyle(.window)

        Window("Monitor Glue", id: "manager") {
            ManagementView()
                .environmentObject(model)
                .environmentObject(permissions)
                .frame(minWidth: 720, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 760, height: 548)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // No Dock icon.
        #if DEBUG
        if DebugPreview.requested != nil {
            DebugPreview.runIfRequested()   // Development harness — skip live watchers/polling.
            return
        }
        #endif
        AppModel.shared.start()
        Updater.shared.start()
        if !Permissions.shared.isTrusted {
            OnboardingController.shared.show()
        }
    }
}

/// Coordinates the watcher, capturer, and restorer; exposes status to the UI.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var currentSetKey: String = ""
    @Published var rememberedCount: Int = 0
    @Published var statusText: String = "Starting…"

    // Richer status surfaced in the menu-bar dropdown.
    @Published var connectedExternalDisplays: Int = 0
    @Published var currentSetLabel: String = ""
    @Published var currentSetWindowCount: Int = 0
    @Published var totalWindowsRemembered: Int = 0

    var isTracking: Bool { connectedExternalDisplays > 0 && Permissions.shared.isTrusted }

    private let watcher = DisplayWatcher()
    private var pollTimer: Timer?
    /// Set while a restore for this monitor set has not yet placed every saved window.
    private var restorePendingKey: String?
    private var restoreGeneration = 0
    private var recheckDebounce: DispatchWorkItem?

    func start() {
        Permissions.shared.refresh()
        if !Permissions.shared.isTrusted { Permissions.shared.startPolling() }

        watcher.onChange = { [weak self] key in
            self?.handleSetChange(key)
        }
        watcher.onGeometryChange = { [weak self] in
            self?.recheckLayout(reason: "display geometry changed")
        }
        watcher.start()
        observeWakeEvents()
        // Hidden apps can become visible without a Space change.
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                // Suppress capture before the transition can expose temporary laptop frames.
                LayoutCapturer.shared.suppressCapture(for: 2)
                self?.resumePendingRestore()
            }
        }
        currentSetKey = watcher.currentKey
        LayoutCapturer.shared.currentSetKey = currentSetKey

        let known = !currentSetKey.isEmpty && LayoutStore.shared.record(for: currentSetKey) != nil
        let names = DisplayInfo.externalDisplays().map { $0.localizedName }.joined(separator: " + ")
        Log.write("LAUNCHED → \(currentSetKey.isEmpty ? "built-in only" : names) known=\(known)")

        // Restore BEFORE the capturer takes its first snapshot. Launching after a monitor was
        // connected (app quit, dock, reopen) looks exactly like a fresh connect: macOS has
        // already dumped the windows onto the built-in display. Capturing that state first
        // would overwrite the saved layout with the half-migrated one, so restore — which
        // suppresses capture while it runs — has to go first.
        if known { restoreWithRetries(currentSetKey) }

        LayoutCapturer.shared.start()

        // Poll as a safety net for missed display-reconfiguration events (sleep/wake, dock
        // swaps). Cheap: it only reads the display list and compares the monitor-set key.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.watcher.poll()
        }

        refreshStatus()
    }

    /// Waking is when layouts are most likely to be wrong and least likely to be noticed: the
    /// displays may come back in a different arrangement, and the Accessibility API can report
    /// no windows for a while, which is how a restore silently placed nothing before.
    private func observeWakeEvents() {
        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, String)] = [
            (NSWorkspace.didWakeNotification, "system wake"),
            (NSWorkspace.screensDidWakeNotification, "screens wake"),
            (NSWorkspace.sessionDidBecomeActiveNotification, "session active"),
        ]
        for (name, reason) in events {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.recheckLayout(reason: reason)
            }
        }

        // Unlocking is the moment windows become visible to the Accessibility API again, and
        // it has no NSWorkspace equivalent — it arrives as a distributed notification.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.recheckLayout(reason: "screen unlocked")
        }
    }

    /// Re-apply the saved layout for whatever is connected now. Safe to call for any reason:
    /// restore is idempotent, so when everything is already in place this costs one log line.
    private func recheckLayout(reason: String) {
        recheckDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.watcher.poll()          // a set change takes priority and handles itself
            let key = self.currentSetKey
            guard !key.isEmpty, LayoutStore.shared.record(for: key) != nil else { return }
            guard self.restorePendingKey != key else { return }   // a restore is already running
            Log.write("RECHECK (\(reason)) → re-applying layout for key=\(key.prefix(8))")
            self.restoreWithRetries(key)
        }
        recheckDebounce = work
        // Wake arrives as a burst (system wake, then screens, then session); coalesce them, and
        // give the displays a moment to settle before reading their geometry.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func handleSetChange(_ key: String) {
        restoreGeneration += 1
        restorePendingKey = nil
        currentSetKey = key
        LayoutCapturer.shared.currentSetKey = key
        let known = !key.isEmpty && LayoutStore.shared.record(for: key) != nil
        let names = DisplayInfo.externalDisplays().map { $0.localizedName }.joined(separator: " + ")
        Log.write("DISPLAY SET CHANGED → \(key.isEmpty ? "built-in only" : names) key=\(key.prefix(8)) known=\(known)")
        if known { restoreWithRetries(key) }
        refreshStatus()
    }

    /// Restore repeatedly after a display connects, until the saved layout is actually on
    /// screen. macOS keeps reshuffling windows for a moment; apps that are still launching have
    /// no windows yet; and right after a wake the Accessibility API can report no windows at
    /// all for a while. Passes are idempotent — a window already in place is left alone.
    ///
    /// Capture stays suppressed for as long as a restore is unfinished. Otherwise a failed
    /// restore gets immortalised: macOS leaves the windows at their built-in-display sizes, and
    /// the next snapshot overwrites the good saved layout with those sizes.
    private func resumePendingRestore() {
        let key = currentSetKey
        guard !key.isEmpty, !LayoutRestorer.pendingWindowIDs(for: key).isEmpty,
              restorePendingKey != key else { return }
        restoreWithRetries(key, newCycle: false)
    }

    private func restoreWithRetries(_ key: String, newCycle: Bool = true) {
        restoreGeneration += 1
        restorePendingKey = key
        if newCycle { LayoutRestorer.beginCycle(setKey: key) }
        LayoutCapturer.shared.suppressCapture(for: 10)
        attemptRestore(key, elapsed: 0, generation: restoreGeneration, enforcePlaced: newCycle)
    }

    /// One restore attempt, rescheduling itself until the layout is on screen. The interval is
    /// short at first because the usual reason a pass places nothing is that apps are still
    /// answering the Accessibility API slowly after the display change — polling every few
    /// hundred milliseconds means we place the windows as soon as they become visible to us,
    /// instead of waiting out a sparse fixed schedule.
    private func attemptRestore(_ key: String, elapsed: Double, generation: Int, enforcePlaced: Bool, lockedWait: Bool = false) {
        // While locked there is nothing to poll for quickly; check back at a calm pace.
        let interval: Double = lockedWait ? 2.0 : (elapsed < 10 ? 0.4 : (elapsed < 30 ? 1.0 : 3.0))
        let giveUpAfter = 180.0

        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            guard self.restoreGeneration == generation else { return }
            guard self.currentSetKey == key else { return }         // display changed again
            guard self.restorePendingKey == key else { return }      // already satisfied

            if SessionState.isScreenLocked {
                // Nothing can be placed at the lock screen. Hold the layout protected and do
                // not let the give-up clock run down, or unlocking ten minutes later would
                // find capture already recording a layout that was never restored.
                LayoutCapturer.shared.suppressCapture(for: 45)
                self.attemptRestore(key, elapsed: elapsed, generation: generation, enforcePlaced: enforcePlaced, lockedWait: true)
                return
            }

            // For the first few seconds keep asserting the saved frames, since macOS is still
            // shuffling windows. After that, respect windows already placed in this cycle so
            // resizing one actually sticks while we wait for some other app to reopen.
            let outcome = LayoutRestorer.restore(setKey: key, enforce: enforcePlaced && elapsed < 5)
            if outcome.isComplete {
                self.restorePendingKey = nil
                // Layout is on screen — let capture take over again shortly.
                LayoutCapturer.shared.suppressCapture(for: 2)
                return
            }

            if outcome.pendingPlacements > 0 {
                // Still actively moving windows — a snapshot now would record a half-done layout.
                LayoutCapturer.shared.suppressCapture(for: 10)
            } else {
                // Everything we can place is placed; the rest is waiting on apps that are not
                // open. Capture has to run, or a resize made now would never be remembered.
                LayoutCapturer.shared.resumeCapture()
            }

            let next = elapsed + interval
            guard next < giveUpAfter else {
                // Give up eventually, or the app would never record layout changes for this set
                // again (e.g. the saved app was closed for good).
                self.restorePendingKey = nil
                LayoutCapturer.shared.resumeCapture()
                Log.write("restore for key=\(key.prefix(8)) never completed after \(Int(next))s — resuming capture; unplaced windows remain protected until their Space becomes available")
                return
            }
            self.attemptRestore(key, elapsed: next, generation: generation, enforcePlaced: enforcePlaced)
        }
    }

    func restoreNow() {
        guard !currentSetKey.isEmpty else { return }
        restoreWithRetries(currentSetKey)
    }

    func refreshStatus() {
        let sets = LayoutStore.shared.allSets()
        rememberedCount = sets.count
        totalWindowsRemembered = sets.reduce(0) { $0 + $1.windows.count }

        let externals = DisplayInfo.externalDisplays()
        connectedExternalDisplays = externals.count

        if let record = LayoutStore.shared.record(for: currentSetKey) {
            currentSetLabel = record.label
            currentSetWindowCount = record.windows.count
        } else {
            currentSetLabel = externals.map { $0.localizedName }.sorted().joined(separator: " + ")
            currentSetWindowCount = 0
        }

        if !Permissions.shared.isTrusted {
            statusText = "Accessibility access needed"
        } else if connectedExternalDisplays == 0 {
            statusText = "Built-in display only — idle"
        } else {
            statusText = "Tracking · \(connectedExternalDisplays) display\(connectedExternalDisplays == 1 ? "" : "s") connected"
        }
    }
}
