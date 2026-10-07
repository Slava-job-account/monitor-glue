import AppKit

/// Continuously snapshots the positions of windows on external displays and persists
/// the freshest layout per monitor-set. Built-in-display windows are ignored.
final class LayoutCapturer {
    static let shared = LayoutCapturer()

    private var timer: Timer?
    private let interval: TimeInterval = 4.0
    private var lastSnapshotHash: Int = 0
    private var lastWrite: Date = .distantPast

    /// The monitor-set key currently being tracked (set by the app on display changes).
    var currentSetKey: String = ""

    /// Capture is paused until this time. Right after a display connects, macOS has usually
    /// not finished moving windows back, so a snapshot then would replace a good saved layout
    /// with a half-migrated one. The app pauses capture while restore runs.
    private var suppressedUntil: Date = .distantPast

    func suppressCapture(for seconds: TimeInterval) {
        suppressedUntil = Date().addingTimeInterval(seconds)
    }

    /// Clear any suppression immediately.
    func resumeCapture() {
        suppressedUntil = .distantPast
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.capture()
        }
        capture()
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// Take one snapshot now. Cheap no-op if nothing changed or no external display.
    /// `force` bypasses the post-connect pause (used by tests).
    func capture(force: Bool = false) {
        guard AXIsProcessTrusted() else { return }
        guard force || Date() >= suppressedUntil else { return }
        let displays = DisplayInfo.liveDisplays()
        let externals = displays.filter { !$0.isBuiltin }
        guard !externals.isEmpty else { return }

        let setKey = DisplayInfo.monitorSetKey(for: displays)
        guard !setKey.isEmpty else { return }
        currentSetKey = setKey

        let live = WindowManager.currentWindows()
        let snapshot = Snapshot(live: live, displays: displays,
                                saved: LayoutStore.shared.record(for: setKey)?.windows ?? [],
                                protected: LayoutRestorer.pendingWindowIDs(for: setKey))
        let layouts = snapshot.windows
        let replaced = snapshot.replaced

        guard !layouts.isEmpty || !replaced.isEmpty else { return }

        // Diff: skip the write if the layout is unchanged (ignore timestamps).
        let hash = ([setKey] + layouts.map { "\($0.id)|\($0.displayUUID)|\($0.windowTitle)|\($0.x)|\($0.y)|\($0.width)|\($0.height)" }.sorted()
            + replaced.sorted()).joined(separator: "\n").hashValue
        // Skip unchanged snapshots, but still write about once a day: the write refreshes each
        // window's "last seen" time, which is what keeps a window that simply never moves from
        // being mistaken for a closed one by the 30-day cleanup.
        guard hash != lastSnapshotHash || Date().timeIntervalSince(lastWrite) > 24 * 60 * 60 else { return }
        lastSnapshotHash = hash
        lastWrite = Date()

        LayoutStore.shared.upsert(
            setKey: setKey,
            displays: DisplayInfo.records(for: displays),
            windows: layouts,
            evictSlots: replaced
        )
        Log.write("captured \(layouts.count) window(s) for \(externals.map { $0.localizedName }.joined(separator: " + "))")
    }

    /// A partial view of the desktop must never replace an entire monitor's history.
    struct Snapshot {
        var windows: [WindowLayout]
        var replaced: Set<String>

        init(live: [LiveWindow], displays: [LiveDisplay], saved: [WindowLayout], protected: Set<String>) {
            var layouts: [WindowLayout] = []
            let now = Date()

            let matched = LayoutMatcher.match(saved, to: live)
            let protectedWindows = Set(matched.compactMap { i, win in
                protected.contains(saved[i].id) ? win.identity : nil
            })
            // Replace matched entries only when observed on screen and fully restored. Inactive
            // Spaces may still have macOS's temporary laptop frames after a disconnect.
            let replaced = Set(matched.compactMap { i, win -> String? in
                guard win.isOnScreen, !protected.contains(saved[i].id),
                      WindowManager.display(for: win, in: displays) != nil else { return nil }
                return saved[i].id
            })

            for win in live where win.isOnScreen && !protectedWindows.contains(win.identity) {
                // Only remember windows that live on an external display.
                guard let disp = WindowManager.display(for: win, in: displays), !disp.isBuiltin else { continue }
                // Store the position RELATIVE to the display's origin, so restore works even when
                // the display comes back at a different arrangement origin next session.
                layouts.append(WindowLayout(
                    appBundleID: win.appBundleID,
                    appName: win.appName,
                    displayUUID: disp.uuid,
                    windowTitle: win.title,
                    windowIndex: win.index,
                    x: win.frame.origin.x - disp.bounds.origin.x,
                    y: win.frame.origin.y - disp.bounds.origin.y,
                    width: win.frame.size.width, height: win.frame.size.height,
                    updatedAt: now,
                    identity: win.identity
                ))
            }

            windows = layouts
            self.replaced = replaced
        }
    }
}
