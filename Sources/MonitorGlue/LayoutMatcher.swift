import AppKit

/// Shared by capture and restore so both identify the same window across Space switches.
enum LayoutMatcher {
    static func match(_ layouts: [WindowLayout], to live: [LiveWindow]) -> [Int: LiveWindow] {
        var assignment: [Int: LiveWindow] = [:]
        var used = Set<Int>()
        func claim(_ i: Int, _ j: Int) { assignment[i] = live[j]; used.insert(j) }

        for (i, layout) in layouts.enumerated() {
            guard let identity = layout.identity else { continue }
            if let j = live.indices.first(where: { !used.contains($0) && live[$0].identity == identity }) {
                claim(i, j)
            }
        }
        // Old files and relaunched apps have no usable window number. Only a unique title
        // is safe: window-list indices and duplicate titles can refer to another Space.
        for (i, layout) in layouts.enumerated() where assignment[i] == nil {
            guard layout.identity?.isRunning != true, !layout.windowTitle.isEmpty else { continue }
            let saved = layouts.indices.filter {
                layouts[$0].appBundleID == layout.appBundleID && layouts[$0].windowTitle == layout.windowTitle
            }
            let candidates = live.indices.filter {
                !used.contains($0) && live[$0].appBundleID == layout.appBundleID && live[$0].title == layout.windowTitle
            }
            if saved.count == 1, candidates.count == 1 { claim(i, candidates[0]) }
        }
        return assignment
    }

    static func reason(_ layout: WindowLayout, _ window: LiveWindow) -> String {
        layout.identity == window.identity ? "window-id" : "title"
    }
}
