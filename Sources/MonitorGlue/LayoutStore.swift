import Foundation

// MARK: - Persisted models

/// One physical display, keyed by its stable UUID.
struct DisplayInfoRecord: Codable, Hashable {
    var uuid: String
    var localizedName: String
    var widthPx: Int
    var heightPx: Int
}

/// A remembered window's saved frame on a specific external display.
struct WindowLayout: Codable, Hashable, Identifiable {
    var id: String { identity?.key ?? "\(appBundleID)#\(displayUUID)#\(windowIndex)#\(windowTitle)" }

    var appBundleID: String
    var appName: String
    var displayUUID: String
    var windowTitle: String
    var windowIndex: Int
    // Frame relative to the saved display origin (top-left coordinates).
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var updatedAt: Date
    var identity: WindowIdentity? = nil

    var frame: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set { x = newValue.origin.x; y = newValue.origin.y; width = newValue.size.width; height = newValue.size.height }
    }
}

/// All remembered windows for one unique set of connected external monitors.
struct MonitorSetRecord: Codable, Identifiable {
    var id: String { key }
    /// Sorted, joined display UUIDs — the persistence key.
    var key: String
    var displays: [DisplayInfoRecord]
    var lastSeen: Date
    var windows: [WindowLayout]

    /// Merge only observed windows, preserving windows on unvisited Spaces.
    mutating func merge(_ captured: [WindowLayout], evicting ids: Set<String>) {
        let replaced = ids.union(captured.map(\.id))
        windows.removeAll { replaced.contains($0.id) }
        windows.append(contentsOf: captured)
    }

    /// Human label like "DELL U2720Q + LG HDR 4K".
    var label: String {
        displays.map { $0.localizedName }.sorted().joined(separator: " + ")
    }
}

/// Top-level persisted document.
struct LayoutStoreData: Codable {
    var monitorSets: [String: MonitorSetRecord] = [:]
}

// MARK: - Store

/// Loads/saves the layout document to Application Support with atomic writes.
final class LayoutStore {
    static let shared = LayoutStore()

    private let queue = DispatchQueue(label: "com.erango.monitorglue.store")
    private(set) var data: LayoutStoreData

    private let fileURL: URL

    init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("MonitorGlue", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("layouts.json")
        self.data = LayoutStore.load(from: fileURL)
    }

    private static func load(from url: URL) -> LayoutStoreData {
        guard let raw = try? Data(contentsOf: url) else { return LayoutStoreData() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded = (try? decoder.decode(LayoutStoreData.self, from: raw)) ?? LayoutStoreData()
        for (key, record) in loaded.monitorSets { loaded.monitorSets[key] = pruned(record) }
        return loaded
    }

    /// A saved window is forgotten once it has gone 30 days without being seen on a monitor
    /// that was itself in use - i.e. its window was closed or moved away for good.
    ///
    /// Measured against the monitor set's own `lastSeen`, not the clock: a monitor that simply
    /// was not plugged in for a month (a holiday) keeps its whole layout, because its windows
    /// and its `lastSeen` aged together. Captures merge, so without this, closed windows would
    /// accumulate for ever and every reconnect would spend its full retry window on them.
    static let staleAfter: TimeInterval = 30 * 24 * 60 * 60

    private static func pruned(_ record: MonitorSetRecord) -> MonitorSetRecord {
        var record = record
        let before = record.windows.count
        record.windows.removeAll { record.lastSeen.timeIntervalSince($0.updatedAt) > staleAfter }
        let dropped = before - record.windows.count
        if dropped > 0 {
            Log.write("forgot \(dropped) window(s) on \(record.label) not seen there for over 30 days")
        }
        return record
    }

    func save() {
        queue.sync {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let raw = try? encoder.encode(data) else { return }
            try? raw.write(to: fileURL, options: .atomic)
        }
    }

    /// Upsert a monitor set's metadata and merge in freshly captured windows.
    ///
    /// Unobserved Spaces retain their saved windows. Matched entries are replaced by the
    /// snapshot (including legacy identities); windows moved to the laptop are only evicted.
    /// - Parameter evictSlots: saved IDs replaced or deliberately moved off the monitor.
    func upsert(setKey: String, displays: [DisplayInfoRecord], windows: [WindowLayout],
                evictSlots: Set<String> = []) {
        queue.sync {
            var record = data.monitorSets[setKey]
                ?? MonitorSetRecord(key: setKey, displays: displays, lastSeen: Date(), windows: [])
            record.displays = displays
            record.lastSeen = Date()

            record.merge(windows, evicting: evictSlots)
            data.monitorSets[setKey] = LayoutStore.pruned(record)
        }
        save()
    }

    /// Record the frame a window actually ended up with, when the app refused the saved one
    /// (Slack will not go below its minimum width, for example). Without this the app would
    /// keep trying to apply a size that can never be reached.
    func replaceFrame(setKey: String, windowID: String, with frame: CGRect) {
        queue.sync {
            guard var record = data.monitorSets[setKey] else { return }
            guard let i = record.windows.firstIndex(where: {
                $0.id == windowID
            }) else { return }
            record.windows[i].frame = frame
            record.windows[i].updatedAt = Date()
            data.monitorSets[setKey] = record
        }
        save()
    }

    func record(for setKey: String) -> MonitorSetRecord? {
        queue.sync { data.monitorSets[setKey] }
    }

    #if DEBUG
    /// Load in-memory records without persisting — used by the gated UI preview harness.
    func injectForPreview(_ injected: LayoutStoreData) {
        queue.sync { data = injected }
    }
    #endif

    func allSets() -> [MonitorSetRecord] {
        queue.sync { Array(data.monitorSets.values).sorted { $0.lastSeen > $1.lastSeen } }
    }

    func deleteAll() {
        queue.sync { data.monitorSets.removeAll() }
        save()
    }

    func deleteSet(key: String) {
        queue.sync { data.monitorSets[key] = nil }
        save()
    }

    func deleteWindow(setKey: String, windowID: String) {
        queue.sync {
            guard var record = data.monitorSets[setKey] else { return }
            record.windows.removeAll { $0.id == windowID }
            data.monitorSets[setKey] = record
        }
        save()
    }

    func deleteApp(setKey: String, bundleID: String) {
        queue.sync {
            guard var record = data.monitorSets[setKey] else { return }
            record.windows.removeAll { $0.appBundleID == bundleID }
            data.monitorSets[setKey] = record
        }
        save()
    }
}
