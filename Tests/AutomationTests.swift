import AppKit
import Foundation

final class FakeWindowBackend: WindowBackend {
    let canDiscoverPaths = false
    var windows: [ManagedWindow] = []
    var activeID: String?
    var zooms: [String: Int] = [:]
    var moves: [String] = []
    var failAfter: Int?
    var focusedID: String?
    var moveFailures = 0
    var moveAttempts = 0

    func scan(_ processes: [ManagedProcess]) -> [ManagedWindow] { windows }
    func move(_ window: ManagedWindow, to frame: CGRect) -> Bool {
        moveAttempts += 1
        if moveFailures > 0 { moveFailures -= 1; return false }
        guard let index = windows.firstIndex(where: { $0.id == window.id }) else { return false }
        let old = windows[index]
        windows[index] = ManagedWindow(id: old.id, app: old.app, pid: old.pid, element: nil, number: old.number,
                                      title: old.title, frame: frame, directory: old.directory)
        moves.append(window.id)
        return true
    }
    func zoomOne(_ window: ManagedWindow) -> Bool {
        guard activeID == window.id, failAfter == nil || zooms[window.id, default: 0] < failAfter! else { return false }
        zooms[window.id, default: 0] += 1
        return true
    }
    func focus(_ window: ManagedWindow) { focusedID = window.id }
    func add(_ id: String, path: String? = nil, x: Double = 30) {
        windows.append(ManagedWindow(id: id, app: "com.apple.Terminal", pid: 1, element: nil, number: nil,
                                     title: id, frame: CGRect(x: x, y: 30, width: 700, height: 500), directory: path))
    }
    func frame(_ id: String) -> CGRect { windows.first { $0.id == id }!.frame }
}

@main
enum AutomationTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(value(), message)
    }

    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalLayoutAutomation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screen = ScreenGeometry(id: "one", frame: CGRect(x: 0, y: 0, width: 1400, height: 900),
                                    usable: CGRect(x: 0, y: 25, width: 1400, height: 850))
        let backend = FakeWindowBackend()
        let ledger = directory.appendingPathComponent("zoom.json")
        let coordinator = WindowCoordinator(ledgerFile: ledger, backend: backend)
        var preferences = Preferences()
        preferences.completedWelcome = true
        let slots = preferences.preset.rectangles(in: screen.usable, gap: preferences.gap)
        backend.add("A", path: "/work/z")
        let originalA = backend.frame("A")
        backend.activeID = "A"
        _ = await coordinator.refresh(processes: [], screens: [screen], preferences: preferences)
        check(backend.zooms["A"] == 4, "New active terminal gets exactly four Bigger Text commands")
        check(backend.frame("A") == slots[0], "A single window already occupies one quarter")
        _ = await coordinator.refresh(processes: [], screens: [screen], preferences: preferences)
        let settledMoves = backend.moves.count
        _ = await coordinator.refresh(processes: [], screens: [screen], preferences: preferences)
        check(backend.zooms["A"] == 4 && backend.moves.count == settledMoves, "Idle polls must not zoom or move again")

        backend.add("B", path: "/work/z")
        backend.activeID = "B"
        _ = await coordinator.refresh(processes: [], screens: [screen], preferences: preferences)
        check(backend.zooms["A"] == 4 && backend.zooms["B"] == 4, "A second window zooms only once")
        check(backend.frame("A") == slots[0] && backend.frame("B") == slots[1], "New windows get consecutive quarters")
        backend.windows.reverse()
        _ = await coordinator.refresh(processes: [], screens: [screen], preferences: preferences)
        check(backend.frame("A") == slots[0], "AX front-to-back order must not reshuffle the layout")

        preferences.automatic = false
        backend.add("C", path: "/work/a")
        backend.activeID = "C"
        let pausedMoves = backend.moves.count
        _ = await coordinator.refresh(processes: [], screens: [screen], preferences: preferences)
        check(backend.zooms["C"] == nil && backend.moves.count == pausedMoves, "Pause stops both window and text changes")
        preferences.automatic = true
        _ = await coordinator.refresh(processes: [], screens: [screen], preferences: preferences)
        check(backend.zooms["C"] == 4 && backend.frame("C") == slots[2], "Resume handles windows opened while paused")
        backend.windows.removeAll { $0.id == "B" }
        _ = await coordinator.refresh(processes: [], screens: [screen], preferences: preferences)
        _ = await coordinator.refresh(processes: [], screens: [screen], preferences: preferences)
        check(backend.frame("C") == slots[1], "Closing a window compacts the remaining layout")
        let manual = CGRect(x: 90, y: 200, width: 300, height: 300)
        _ = backend.move(backend.windows.first { $0.id == "C" }!, to: manual)
        let afterDrag = backend.moves.count
        _ = await coordinator.refresh(processes: [], screens: [screen], preferences: preferences)
        check(backend.moves.count == afterDrag && backend.frame("C") == manual, "Manual dragging is respected between topology changes")

        preferences.groupByDirectory = true
        let grouped = await coordinator.refresh(processes: [], screens: [screen], preferences: preferences)
        check(grouped.windows.map(\.id) == ["C", "A"], "Groups use exact full local paths")
        check(backend.frame("C") == slots[0] && backend.frame("A") == slots[1], "Related path groups occupy adjacent slots")
        backend.add("D")
        backend.activeID = nil
        let pending = await coordinator.refresh(processes: [], screens: [screen], preferences: preferences)
        check(pending.pendingZoom && backend.zooms["D"] == nil, "Inactive windows wait without stealing focus")
        check(pending.windows.last?.id == "D", "An unknown folder stays explicitly unknown")
        backend.activeID = "D"
        _ = await coordinator.refresh(processes: [], screens: [screen], preferences: preferences)
        check(backend.zooms["D"] == 4, "Pending text size applies when the window becomes active")
        let relaunched = WindowCoordinator(ledgerFile: ledger, backend: backend)
        _ = await relaunched.refresh(processes: [], screens: [screen], preferences: preferences)
        check(backend.zooms["A"] == 4 && backend.zooms["C"] == 4 && backend.zooms["D"] == 4,
              "Persisted progress prevents repeated enlargement after an app restart")
        await coordinator.focus(id: "C")
        check(backend.focusedID == "C", "Folder overview focuses the selected window")
        let restoreFailures = await coordinator.restore()
        check(restoreFailures == 0 && backend.frame("A") == originalA, "Restore returns existing windows to their original positions")

        let partial = FakeWindowBackend()
        partial.add("E")
        partial.activeID = "E"
        partial.failAfter = 2
        let partialLedger = directory.appendingPathComponent("partial.json")
        let retry = WindowCoordinator(ledgerFile: partialLedger, backend: partial)
        let failed = await retry.refresh(processes: [], screens: [screen], preferences: preferences)
        check(failed.pendingZoom && partial.zooms["E"] == 2, "A failed action records only successful text steps")
        partial.failAfter = nil
        _ = await retry.refresh(processes: [], screens: [screen], preferences: preferences)
        check(partial.zooms["E"] == 4, "Retry completes only the remaining two steps")
        let decoded = try JSONDecoder().decode(ZoomLedger.self, from: Data(contentsOf: partialLedger))
        check(decoded.applied["E"] == 4, "Successful steps are journaled")

        let cancelled = FakeWindowBackend()
        cancelled.add("F")
        cancelled.activeID = "F"
        let lease = AutomationLease()
        lease.cancel()
        let cancellation = WindowCoordinator(ledgerFile: directory.appendingPathComponent("cancelled.json"), backend: cancelled)
        _ = await cancellation.refresh(processes: [], screens: [screen], preferences: preferences, lease: lease)
        check(cancelled.moves.isEmpty && cancelled.zooms.isEmpty, "A cancelled in-flight poll cannot change any windows")

        let overflow = FakeWindowBackend()
        for id in ["1", "2", "3", "4", "5"] { overflow.add(id) }
        let fifthFrame = overflow.frame("5")
        let bounded = WindowCoordinator(ledgerFile: directory.appendingPathComponent("bounded.json"), backend: overflow)
        _ = await bounded.refresh(processes: [], screens: [screen], preferences: Preferences())
        check(overflow.moves.count == 4 && overflow.frame("5") == fifthFrame, "Extra windows stay untouched instead of overlapping quarters")

        let multi = FakeWindowBackend()
        multi.add("left", x: 100)
        multi.add("right", x: 1600)
        let second = ScreenGeometry(id: "two", frame: CGRect(x: 1400, y: 0, width: 1400, height: 900),
                                    usable: CGRect(x: 1400, y: 25, width: 1400, height: 850))
        let multiCoordinator = WindowCoordinator(ledgerFile: directory.appendingPathComponent("multi.json"), backend: multi)
        _ = await multiCoordinator.refresh(processes: [], screens: [screen, second], preferences: Preferences())
        check(multi.frame("left") == slots[0] && multi.frame("right").minX > 1400, "Each display has its own four-quarter layout")
        let initializing = FakeWindowBackend()
        initializing.add("initializing")
        initializing.moveFailures = 2
        var noZoom = Preferences()
        noZoom.enlargeText = false
        let delayed = WindowCoordinator(ledgerFile: directory.appendingPathComponent("delayed.json"), backend: initializing)
        for _ in 0..<5 { _ = await delayed.refresh(processes: [], screens: [screen], preferences: noZoom) }
        check(initializing.moveAttempts == 3 && initializing.frame("initializing") == slots[0],
              "A briefly unavailable new window is retried and then left alone")
        let refusing = FakeWindowBackend()
        refusing.add("refusing")
        refusing.moveFailures = 100
        let boundedRetries = WindowCoordinator(ledgerFile: directory.appendingPathComponent("refusing.json"), backend: refusing)
        for _ in 0..<8 { _ = await boundedRetries.refresh(processes: [], screens: [screen], preferences: noZoom) }
        check(refusing.moveAttempts == 4, "A window which permanently rejects resizing is not fought indefinitely")
        let quick = FakeWindowBackend()
        quick.add("old")
        quick.add("newLeft")
        quick.add("newRight")
        for index in quick.windows.indices {
            let w = quick.windows[index]
            quick.windows[index] = ManagedWindow(id: w.id, app: w.app, pid: w.pid, element: nil,
                number: index + 1, title: w.title, frame: w.frame, directory: w.directory)
        }
        let quickCoordinator = WindowCoordinator(ledgerFile: directory.appendingPathComponent("quick.json"), backend: quick)
        _ = await quickCoordinator.refresh(processes: [], screens: [screen], preferences: noZoom)
        let oldFrame = quick.frame("old")
        try await quickCoordinator.adoptQuickWindows(numbers: [2, 3], processes: [], zoomSteps: 4)
        var two = Preferences()
        two.preset = .columns
        quick.activeID = "newLeft"
        _ = await quickCoordinator.refresh(processes: [], screens: [screen], preferences: two)
        let halves = LayoutPreset.columns.rectangles(in: screen.usable, gap: two.gap)
        check(quick.frame("newLeft") == halves[0] && quick.frame("newRight") == halves[1],
              "Quick windows take symmetric slots ahead of existing windows")
        check(quick.frame("old") == oldFrame, "Quick launch leaves extra existing windows in place")
        check(quick.zooms["newLeft"] == nil, "Pre-enlarged quick windows are not enlarged again")
        quick.activeID = "newRight"
        _ = await quickCoordinator.refresh(processes: [], screens: [screen], preferences: two)
        check(quick.zooms["newRight"] == nil, "Switching quick window focus does not repeat text sizing")
        print("Passed \(checks) automation checks: new windows, exactly four text steps, restart persistence, pause, retry, folder groups, cancellation and multiple displays.")
    }
}
