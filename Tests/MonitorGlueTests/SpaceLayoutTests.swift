import XCTest
import AppKit
@testable import MonitorGlue

final class SpaceLayoutTests: XCTestCase {
    private let external = LiveDisplay(displayID: 2, uuid: "external", isBuiltin: false,
                                       localizedName: "Monitor", bounds: CGRect(x: 1000, y: 0, width: 2000, height: 1200),
                                       widthPx: 2000, heightPx: 1200)
    private let builtin = LiveDisplay(displayID: 1, uuid: "builtin", isBuiltin: true,
                                      localizedName: "Laptop", bounds: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                      widthPx: 1000, heightPx: 800)

    private func window(_ number: UInt32, title: String = "Untitled", index: Int = 0,
                        visible: Bool = true, x: CGFloat = 1200) -> LiveWindow {
        let pid: pid_t = 999_999_999
        return LiveWindow(element: AXUIElementCreateApplication(pid),
                          appBundleID: "test.editor", appName: "Editor",
                          title: title, index: index, frame: CGRect(x: x, y: 100, width: 500, height: 400),
                          identity: WindowIdentity(pid: pid,
                                                   launchedAt: 1_791_363_600.123456, number: number),
                          isOnScreen: visible)
    }

    private func layout(_ window: LiveWindow) -> WindowLayout {
        WindowLayout(appBundleID: window.appBundleID, appName: window.appName, displayUUID: external.uuid,
                     windowTitle: window.title, windowIndex: window.index, x: 200, y: 100,
                     width: 500, height: 400, updatedAt: Date(), identity: window.identity)
    }

    private func record(_ windows: [WindowLayout]) -> MonitorSetRecord {
        MonitorSetRecord(key: "external", displays: [], lastSeen: Date(), windows: windows)
    }

    func testIdenticalTitlesAndIndicesOnDifferentSpacesMatchByIdentity() {
        let first = window(10), second = window(20, visible: false)
        let matched = LayoutMatcher.match([layout(first), layout(second)], to: [second, first])
        XCTAssertEqual(matched[0]?.identity, first.identity)
        XCTAssertEqual(matched[1]?.identity, second.identity)
    }

    func testRenamedWindowKeepsItsSavedLayout() {
        let original = window(10)
        let renamed = window(10, title: "Project B", index: 5)
        let matched = LayoutMatcher.match([layout(original)], to: [renamed])
        XCTAssertEqual(matched[0]?.identity, original.identity)
    }

    func testUnvisitedWindowCannotStealAnotherWindowsLayout() {
        let saved = [layout(window(10)), layout(window(20))]
        let matched = LayoutMatcher.match(saved, to: [window(20)])
        XCTAssertNil(matched[0])
        XCTAssertEqual(matched[1]?.identity, window(20).identity)
    }

    func testLegacyLayoutWithUniqueTitleStillRestores() {
        let live = window(10, title: "Project A")
        var saved = layout(live)
        saved.identity = nil
        XCTAssertEqual(LayoutMatcher.match([saved], to: [live])[0]?.identity, live.identity)
    }

    func testLegacyDuplicateTitlesDoNotGuessByWindowIndex() {
        var first = layout(window(10, index: 0)), second = layout(window(20, index: 1))
        first.identity = nil
        second.identity = nil
        XCTAssertTrue(LayoutMatcher.match([first, second], to: [window(20, index: 0)]).isEmpty)
    }

    func testRelaunchedAppCanMatchAnUnambiguousTitle() {
        let live = window(10, title: "Project A")
        var saved = layout(live)
        saved.identity?.launchedAt = 0
        XCTAssertEqual(LayoutMatcher.match([saved], to: [live])[0]?.identity, live.identity)
    }

    func testIdentitySurvivesTheStoresISO8601Encoding() throws {
        let saved = layout(window(10))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WindowLayout.self, from: encoder.encode(saved))
        XCTAssertEqual(decoded.identity, saved.identity)
        XCTAssertEqual(decoded.id, saved.id)
    }

    func testOldLayoutFilesDecodeWithoutIdentity() throws {
        let data = Data("""
        {"monitorSets":{"external":{"key":"external","displays":[],"lastSeen":"2026-10-07T09:00:00Z",
        "windows":[{"appBundleID":"test.editor","appName":"Editor","displayUUID":"external",
        "windowTitle":"Project A","windowIndex":0,"x":200,"y":100,"width":500,"height":400,
        "updatedAt":"2026-10-07T09:00:00Z"}]}}}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try XCTUnwrap(try decoder.decode(LayoutStoreData.self, from: data).monitorSets["external"])
        XCTAssertNil(saved.windows[0].identity)
        XCTAssertEqual(saved.windows[0].windowTitle, "Project A")
    }

    func testPartialCapturePreservesOtherSpacesWithIdenticalWindowIndices() {
        let first = window(10), second = window(20, visible: false)
        var saved = record([layout(first), layout(second)])
        let snapshot = LayoutCapturer.Snapshot(live: [first, second], displays: [builtin, external],
                                              saved: saved.windows, protected: [])
        saved.merge(snapshot.windows, evicting: snapshot.replaced)
        XCTAssertEqual(Set(saved.windows.map(\.id)), Set([layout(first).id, layout(second).id]))
        XCTAssertEqual(snapshot.windows.count, 1)
    }

    func testPendingWindowOnLaptopIsNotForgotten() {
        let original = layout(window(10))
        let snapshot = LayoutCapturer.Snapshot(live: [window(10, x: 100)], displays: [builtin, external],
                                              saved: [original], protected: [original.id])
        XCTAssertTrue(snapshot.windows.isEmpty)
        XCTAssertTrue(snapshot.replaced.isEmpty)
    }

    func testPendingWindowOnExternalMonitorDoesNotOverwriteSavedSize() {
        let original = layout(window(10))
        var resized = window(10)
        resized.frame.size.width = 200
        let snapshot = LayoutCapturer.Snapshot(live: [resized], displays: [builtin, external],
                                              saved: [original], protected: [original.id])
        var saved = record([original])
        saved.merge(snapshot.windows, evicting: snapshot.replaced)
        XCTAssertEqual(saved.windows[0].width, original.width)
    }

    func testMovingLastVisibleWindowToLaptopForgetsOnlyThatWindow() {
        let first = layout(window(10)), second = layout(window(20, visible: false))
        let snapshot = LayoutCapturer.Snapshot(live: [window(10, x: 100), window(20, visible: false)],
                                              displays: [builtin, external], saved: [first, second], protected: [])
        var saved = record([first, second])
        saved.merge(snapshot.windows, evicting: snapshot.replaced)
        XCTAssertEqual(saved.windows.map(\.id), [second.id])
    }

    func testCaptureMigratesLegacyEntryWithoutCreatingDuplicate() {
        let live = window(10, title: "Project A")
        var legacy = layout(live)
        legacy.identity = nil
        let snapshot = LayoutCapturer.Snapshot(live: [live], displays: [builtin, external], saved: [legacy], protected: [])
        var saved = record([legacy])
        saved.merge(snapshot.windows, evicting: snapshot.replaced)
        XCTAssertEqual(saved.windows.count, 1)
        XCTAssertEqual(saved.windows[0].identity, live.identity)
    }

    func testRenameUpdatesExistingEntryInsteadOfAccumulatingOldTitles() {
        let first = layout(window(10))
        var saved = record([first])
        saved.merge([layout(window(10, title: "Renamed"))], evicting: [])
        XCTAssertEqual(saved.windows.count, 1)
        XCTAssertEqual(saved.windows[0].windowTitle, "Renamed")
    }
}
