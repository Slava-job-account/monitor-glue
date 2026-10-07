import AppKit

/// Repositions windows to their saved frames when a known monitor set reconnects.
/// Inaccessible Spaces remain pending until their windows become available.
enum LayoutRestorer {

    /// Last logged outcome and how many identical ones followed it. Retries now run several
    /// times a second, and an unchanged failure repeated 25 times is noise, not information.
    private static var lastSignature = ""
    private static var suppressedRepeats = 0

    /// Unplaced saved IDs stay protected from capture, even after retries stop.
    private static var cycleKey = ""
    private static var pending = Set<String>()

    static func pendingWindowIDs(for key: String) -> Set<String> {
        key == cycleKey ? pending : []
    }

    /// The frame each layout actually ended up with on the previous attempt. Some apps refuse a
    /// size outright (Slack will not go narrower than its minimum), so the target can never be
    /// reached; when two attempts land on the same frame we accept it instead of retrying for
    /// ever and re-applying it over whatever the user does.
    private static var lastAchieved = [String: CGRect]()

    /// Start a new restore cycle for a display change; forget what was placed in the last one.
    static func beginCycle(setKey: String) {
        cycleKey = setKey
        pending = Set(LayoutStore.shared.record(for: setKey)?.windows.map(\.id) ?? [])
        lastAchieved.removeAll()
    }

    /// Result of one restore pass. `missing` counts saved windows that had no open window to
    /// place — the signal that the layout on screen is not yet the saved one, so the caller
    /// should keep retrying and must not let capture overwrite the saved layout.
    struct Outcome {
        var placed: Int = 0
        /// Saved windows with no open window to place - nothing can be done until the app
        /// reopens, so this keeps the retries running.
        var missing: Int = 0
        /// Matched windows that are not yet sitting at their saved frame. While this is above
        /// zero we are still actively placing, and capture must not record the half-done state.
        var pendingPlacements: Int = 0
        var isComplete: Bool { missing == 0 && pendingPlacements == 0 }
    }

    /// - Parameter enforce: re-apply saved frames even to windows already placed in this cycle.
    ///   True only for the first seconds after a display change, while macOS is still shuffling
    ///   windows; afterwards a placed window is left alone so resizing it actually sticks.
    @discardableResult
    static func restore(setKey: String, enforce: Bool = true) -> Outcome {
        guard AXIsProcessTrusted() else {
            Log.write("restore skipped — no Accessibility access")
            return Outcome()
        }
        guard let record = LayoutStore.shared.record(for: setKey) else {
            Log.write("restore skipped — no saved layout for set '\(setKey)'")
            return Outcome()
        }

        pending.formIntersection(record.windows.map(\.id))
        let displays = DisplayInfo.liveDisplays()
        let live = WindowManager.currentWindows()
        let liveByBundle = Dictionary(grouping: live, by: { $0.appBundleID })
        // Only restore to displays that are actually present now, keyed by UUID.
        let displaysByUUID = Dictionary(uniqueKeysWithValues: displays.map { ($0.uuid, $0) })

        let restorable = record.windows.filter { displaysByUUID[$0.displayUUID] != nil }
        let assignment = LayoutMatcher.match(restorable, to: live)

        // Retry passes are usually no-ops; log those as one line so real events stay visible.
        var details: [String] = []
        var alreadyInPlace = 0
        var moved = 0
        var pendingPlacements = 0
        for (i, layout) in restorable.enumerated() {
            guard let disp = displaysByUUID[layout.displayUUID] else { continue }
            // Saved coords are relative to the display origin → map to its current position.
            let target = CGRect(x: disp.bounds.origin.x + layout.x,
                                y: disp.bounds.origin.y + layout.y,
                                width: layout.width, height: layout.height)
            guard let win = assignment[i] else {
                details.append("  MISS \(layout.appName) idx=\(layout.windowIndex) '\(layout.windowTitle.prefix(28))' — no open window to place")
                continue
            }
            // Once restored, leave user moves/resizes and freshly captured layouts alone.
            if !enforce, !pending.contains(layout.id) {
                moved += 1
                alreadyInPlace += 1
                continue
            }
            if win.frame.matches(target) {
                moved += 1
                alreadyInPlace += 1
                pending.remove(layout.id)
                continue
            }
            let ok = WindowManager.setFrame(win.element, target)
            let actual = WindowManager.frame(of: win.element) ?? .zero
            var note = ""
            if ok {
                moved += 1
                pending.remove(layout.id)
            } else if win.isOnScreen, actual.width > 0, actual.height > 0,
                      disp.bounds.contains(CGPoint(x: actual.midX, y: actual.midY)),
                      let previous = lastAchieved[layout.id], previous.matches(actual) {
                // Second attempt landed in exactly the same place: the app will not accept the
                // saved frame. Take what it gives, remember that, and stop fighting it.
                moved += 1
                pending.remove(layout.id)
                let settled = CGRect(x: actual.origin.x - disp.bounds.origin.x,
                                     y: actual.origin.y - disp.bounds.origin.y,
                                     width: actual.width, height: actual.height)
                LayoutStore.shared.replaceFrame(setKey: setKey, windowID: layout.id, with: settled)
                note = " — app refused this frame; saving what it allows"
            } else {
                lastAchieved[layout.id] = actual
                if win.isOnScreen { pendingPlacements += 1 }
            }
            details.append("  \(ok ? "OK  " : "BAD ") \(layout.appName) idx=\(layout.windowIndex) via=\(LayoutMatcher.reason(layout, win)) '\(win.title.prefix(24))' want=\(str(target)) got=\(str(actual))\(note)")
        }

        let missing = restorable.count - assignment.count

        // Collapse a run of identical attempts into one line plus a count.
        let signature = "\(setKey)|\(assignment.count)|\(moved)|\(missing)|\(details.count)"
        if signature == lastSignature, missing > 0 {
            suppressedRepeats += 1
            return Outcome(placed: moved, missing: missing, pendingPlacements: pendingPlacements)
        }
        if suppressedRepeats > 0 {
            Log.write("  (\(suppressedRepeats) further identical attempt(s))")
            suppressedRepeats = 0
        }
        lastSignature = signature

        if details.isEmpty {
            Log.write("restore '\(record.label)': nothing to do — \(alreadyInPlace)/\(restorable.count) already in place")
        } else {
            Log.write("restore '\(record.label)': \(record.windows.count) saved, \(restorable.count) on present displays, \(assignment.count) matched, \(alreadyInPlace) already in place; AX reported \(live.count) window(s) across \(liveByBundle.count) app(s)")
            details.forEach { Log.write($0) }
            Log.write("restore done: \(moved)/\(restorable.count) placed\(missing > 0 ? ", \(missing) still missing" : "")")
        }
        return Outcome(placed: moved, missing: missing, pendingPlacements: pendingPlacements)
    }

    private static func str(_ r: CGRect) -> String {
        "(\(Int(r.origin.x)),\(Int(r.origin.y)) \(Int(r.width))x\(Int(r.height)))"
    }

}
