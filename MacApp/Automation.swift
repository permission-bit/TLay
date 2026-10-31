import AppKit
import ApplicationServices

struct ManagedProcess {
    let id: String
    let pid: pid_t
    let launched: Double
}
struct ScreenGeometry {
    let id: String
    let frame: CGRect
    let usable: CGRect
}
struct ManagedWindow: Identifiable {
    let id: String
    let app: String
    let pid: pid_t
    let element: AXUIElement?
    let number: Int?
    let title: String
    let frame: CGRect
    var directory: String?
    var isTerminal: Bool { app == "com.apple.Terminal" || app == "com.googlecode.iterm2" }
}
struct AutomationReport {
    var windows: [ManagedWindow] = []
    var moved = 0
    var failed = 0
    var pendingZoom = false
    var canUndo = false
    var pathAccessIssue = false
    var ledgerError: String?
}

final class AutomationLease: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

protocol WindowBackend {
    var canDiscoverPaths: Bool { get }
    func scan(_ processes: [ManagedProcess]) -> [ManagedWindow]
    func move(_ window: ManagedWindow, to frame: CGRect) -> Bool
    func zoomOne(_ window: ManagedWindow) -> Bool
    func focus(_ window: ManagedWindow)
}

struct NativeWindowBackend: WindowBackend {
    var canDiscoverPaths: Bool { true }
    func scan(_ processes: [ManagedProcess]) -> [ManagedWindow] {
        var result: [ManagedWindow] = []
        let cgWindows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for process in processes {
            let app = AXUIElementCreateApplication(process.pid)
            AXUIElementSetMessagingTimeout(app, 0.6)
            guard let windows = WindowManager.attribute(app, kAXWindowsAttribute as CFString) as? [AXUIElement] else { continue }
            for element in windows {
                guard WindowManager.attribute(element, kAXSubroleAttribute as CFString) as? String == kAXStandardWindowSubrole,
                      WindowManager.attribute(element, kAXMinimizedAttribute as CFString) as? Bool != true,
                      WindowManager.attribute(element, "AXFullScreen" as CFString) as? Bool != true,
                      let frame = WindowManager.frame(element) else { continue }
                var number = (WindowManager.attribute(element, "AXWindowNumber" as CFString) as? NSNumber)?.intValue
                if number == 0 { number = nil }
                if number == nil {
                    let matching = cgWindows.filter { info in
                        guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == process.pid,
                              (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                              let bounds = info[kCGWindowBounds as String] as? [String: Any],
                              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
                        return abs(rect.minX - frame.minX) < 2 && abs(rect.minY - frame.minY) < 2
                            && abs(rect.width - frame.width) < 2 && abs(rect.height - frame.height) < 2
                    }
                    if matching.count == 1 { number = (matching[0][kCGWindowNumber as String] as? NSNumber)?.intValue }
                }
                let identity = number.map(String.init) ?? String(CFHash(element))
                let key = "\(process.id):\(process.pid):\(process.launched):\(identity)"
                let title = WindowManager.attribute(element, kAXTitleAttribute as CFString) as? String ?? ""
                let document = WindowManager.attribute(element, kAXDocumentAttribute as CFString) as? String
                let directory = document.flatMap { value -> String? in
                    guard let url = URL(string: value), url.isFileURL else { return nil }
                    return url.standardizedFileURL.path
                }
                result.append(ManagedWindow(id: key, app: process.id, pid: process.pid, element: element,
                    number: number, title: title, frame: frame, directory: directory))
            }
        }
        return result
    }

    func move(_ window: ManagedWindow, to frame: CGRect) -> Bool {
        guard let element = window.element else { return false }
        guard WindowManager.setFrame(frame, window: element),
              let actual = WindowManager.frame(element) else { return false }
        return abs(actual.width - frame.width) < 24 && abs(actual.height - frame.height) < 24
            && abs(actual.minX - frame.minX) < 24 && abs(actual.minY - frame.minY) < 24
    }

    // Invoke the terminal's own Bigger Text command, once per step. No global key injection.
    func zoomOne(_ window: ManagedWindow) -> Bool {
        // Wait until a stable native ID is available so app restarts cannot reapply a boost.
        guard window.isTerminal, window.number != nil, let element = window.element else { return false }
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, 0.6)
        guard WindowManager.attribute(app, kAXFrontmostAttribute as CFString) as? Bool == true,
              let focused = WindowManager.attribute(app, kAXFocusedWindowAttribute as CFString),
              CFEqual(focused, element),
              let menuBar = WindowManager.attribute(app, kAXMenuBarAttribute as CFString),
              CFGetTypeID(menuBar) == AXUIElementGetTypeID(),
              let command = biggerCommand(in: menuBar as! AXUIElement, depth: 0) else { return false }
        // Recheck focus after the menu search, in case the user switched windows.
        guard WindowManager.attribute(app, kAXFrontmostAttribute as CFString) as? Bool == true,
              let stillFocused = WindowManager.attribute(app, kAXFocusedWindowAttribute as CFString),
              CFEqual(stillFocused, element) else { return false }
        return AXUIElementPerformAction(command, kAXPressAction as CFString) == .success
    }

    private func biggerCommand(in element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 5 else { return nil }
        let character = WindowManager.attribute(element, kAXMenuItemCmdCharAttribute as CFString) as? String
        let modifiers = (WindowManager.attribute(element, kAXMenuItemCmdModifiersAttribute as CFString) as? NSNumber)?.intValue ?? 0
        if (character == "+" || character == "="), modifiers & 14 == 0,
           WindowManager.attribute(element, kAXEnabledAttribute as CFString) as? Bool != false {
            return element
        }
        let children = WindowManager.attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
        for child in children {
            if let found = biggerCommand(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    func focus(_ window: ManagedWindow) {
        guard let element = window.element else { return }
        NSRunningApplication(processIdentifier: window.pid)?.activate(options: .activateIgnoringOtherApps)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
    }
}

actor WindowCoordinator {
    private let backend: any WindowBackend
    private let ledgerFile: URL
    private var ledger = ZoomLedger()
    private var originals: [String: ManagedWindow] = [:]
    private var current: [ManagedWindow] = []
    private var order: [String: Int] = [:]
    private var quickWindowNumbers: [Int] = []
    private var nextOrder = 0
    private var lastSignature: [String] = []
    private var lastOptions: String?
    private var settleLayout = false
    private var retries = 0
    private var ledgerFailure: String?
    private var pathDiscovery = DirectoryDiscovery()
    private var pathRefresh = Date.distantPast
    private var cachedPaths: [String: String] = [:]
    private var pathIssue = false
    private var wasGrouping = false
    private var pathTask: Task<Void, Never>?
    private var pathGeneration = 0

    init(ledgerFile: URL, backend: any WindowBackend = NativeWindowBackend()) {
        self.ledgerFile = ledgerFile
        self.backend = backend
        if FileManager.default.fileExists(atPath: ledgerFile.path) {
            do { ledger = try JSONDecoder().decode(ZoomLedger.self, from: Data(contentsOf: ledgerFile)) }
            catch { ledgerFailure = error.localizedDescription }
        }
    }

    func refresh(processes: [ManagedProcess], screens: [ScreenGeometry],
                 preferences: Preferences, force: Bool = false, lease: AutomationLease? = nil) -> AutomationReport {
        var report = AutomationReport()
        var windows = backend.scan(processes)
        for window in windows where order[window.id] == nil {
            order[window.id] = nextOrder
            nextOrder += 1
        }
        if preferences.groupByDirectory && backend.canDiscoverPaths {
            if !wasGrouping { pathDiscovery.reset(); pathRefresh = .distantPast }
            let newWindow = windows.contains { $0.isTerminal && cachedPaths[$0.id] == nil }
            if pathTask == nil && (Date().timeIntervalSince(pathRefresh) > 3 || (newWindow && Date().timeIntervalSince(pathRefresh) > 1)) {
                let provider = pathDiscovery
                let input = windows
                let generation = pathGeneration
                pathRefresh = Date()
                // Folder discovery can require a consent dialog. It must never delay layout or text sizing.
                pathTask = Task.detached { [weak self] in
                    var discovery = provider
                    let result = discovery.paths(for: input, processes: processes)
                    await self?.receivePaths(result, provider: discovery, generation: generation)
                }
            }
            for index in windows.indices where windows[index].directory == nil {
                windows[index].directory = cachedPaths[windows[index].id]
            }
        } else if wasGrouping {
            pathGeneration += 1
            pathTask?.cancel()
            pathTask = nil
            cachedPaths = [:]
            pathIssue = false
        }
        wasGrouping = preferences.groupByDirectory
        windows.sort {
            let aQuick = $0.app == "com.apple.Terminal" ? $0.number.flatMap { quickWindowNumbers.firstIndex(of: $0) } : nil
            let bQuick = $1.app == "com.apple.Terminal" ? $1.number.flatMap { quickWindowNumbers.firstIndex(of: $0) } : nil
            if aQuick != nil || bQuick != nil {
                return (aQuick ?? Int.max) < (bQuick ?? Int.max)
            }
            if preferences.groupByDirectory {
                let a = $0.isTerminal ? $0.directory ?? "\u{10FFFF}" : "\u{10FFFF}"
                let b = $1.isTerminal ? $1.directory ?? "\u{10FFFF}" : "\u{10FFFF}"
                if a != b { return a < b }
            }
            return (order[$0.id] ?? 0) < (order[$1.id] ?? 0)
        }
        current = windows
        report.windows = windows
        report.pathAccessIssue = preferences.groupByDirectory && pathIssue

        let active = preferences.automatic || force
        var zoomed = false
        if active && preferences.enlargeText && ledgerFailure == nil {
            for window in windows where window.isTerminal {
                let remaining = ledger.remaining(for: window.id, target: preferences.zoomSteps)
                for _ in 0..<remaining {
                    if lease?.isCancelled == true { break }
                    guard backend.zoomOne(window) else { report.pendingZoom = true; break }
                    ledger.didZoom(window.id)
                    zoomed = true
                    do {
                        try FileManager.default.createDirectory(at: ledgerFile.deletingLastPathComponent(),
                                                                withIntermediateDirectories: true)
                        try JSONEncoder().encode(ledger).write(to: ledgerFile, options: .atomic)
                    } catch {
                        ledgerFailure = error.localizedDescription
                        break
                    }
                }
                if ledgerFailure != nil || lease?.isCancelled == true { break }
            }
        }
        report.ledgerError = ledgerFailure
        let signature = windows.map { window in
            "\(window.id)|\(screen(for: window.frame, screens: screens)?.id ?? "")|\(preferences.groupByDirectory ? window.directory ?? "" : "")"
        }
        let options = "\(preferences.preset.rawValue)|\(preferences.gap)|\(preferences.selectedApps)|\(screens.map { "\($0.id):\($0.usable)" })"
        let changed = signature != lastSignature || options != lastOptions
        if active && lease?.isCancelled != true && (force || zoomed || changed || settleLayout) {
            if changed || force { retries = 3 }
            for display in screens {
                let matching = windows.filter { screen(for: $0.frame, screens: screens)?.id == display.id }
                let frames = preferences.preset.rectangles(in: display.usable, gap: preferences.gap)
                for (window, frame) in zip(matching, frames) {
                    if lease?.isCancelled == true { break }
                    if originals[window.id] == nil { originals[window.id] = window }
                    let fittedQuickWindow = window.app == "com.apple.Terminal"
                        && window.number.map(quickWindowNumbers.contains) == true
                        && frame.contains(window.frame)
                    if fittedQuickWindow || backend.move(window, to: frame) { report.moved += 1 }
                    else { report.failed += 1 }
                }
            }
            if lease?.isCancelled != true {
                lastSignature = signature
                lastOptions = options
            }
            // A new terminal can still be initializing; retry a bounded number of times.
            settleLayout = zoomed || (report.failed > 0 && retries > 0)
            if report.failed > 0 { retries = max(0, retries - 1) }
        }
        report.canUndo = !originals.isEmpty
        return report
    }

    private func screen(for frame: CGRect, screens: [ScreenGeometry]) -> ScreenGeometry? {
        screens.max { a, b in
            let first = a.frame.intersection(frame)
            let second = b.frame.intersection(frame)
            return (first.isNull ? 0 : first.width * first.height) < (second.isNull ? 0 : second.width * second.height)
        }
    }

    // Record text sizing done by the launcher so polling never enlarges it twice.
    func adoptQuickWindows(numbers: [Int], processes: [ManagedProcess], zoomSteps: Int) throws {
        quickWindowNumbers = numbers
        for window in backend.scan(processes) where window.app == "com.apple.Terminal" && window.number.map(numbers.contains) == true {
            for _ in 0..<ledger.remaining(for: window.id, target: zoomSteps) { ledger.didZoom(window.id) }
        }
        try FileManager.default.createDirectory(at: ledgerFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ledger).write(to: ledgerFile, options: .atomic)
        lastSignature = []
    }

    func restore() -> Int {
        var failures = 0
        for (id, window) in originals {
            guard current.contains(where: { $0.id == id }) else { originals.removeValue(forKey: id); continue }
            if backend.move(window, to: window.frame) { originals.removeValue(forKey: id) }
            else { failures += 1 }
        }
        lastSignature = []
        settleLayout = false
        return failures
    }

    func focus(id: String) {
        if let window = current.first(where: { $0.id == id }) { backend.focus(window) }
    }
    func retryDirectories() {
        pathGeneration += 1
        pathTask?.cancel()
        pathTask = nil
        pathDiscovery.reset()
        pathRefresh = .distantPast
    }
    private func receivePaths(_ result: DirectoryResult, provider: DirectoryDiscovery, generation: Int) {
        guard generation == pathGeneration else { return }
        pathDiscovery = provider
        cachedPaths = result.paths
        pathIssue = result.accessIssue
        pathTask = nil
    }
}


// Run away from the UI thread; no commands are typed into existing sessions.
enum QuickTerminalLauncher {
    static func open(frames: [CGRect], zoomSteps: Int) throws -> [Int] {
        let placements = frames.map { rect in
            "{\(Int(ceil(rect.minX))), \(Int(ceil(rect.minY))), \(Int(floor(rect.maxX))), \(Int(floor(rect.maxY)))}"
        }.joined(separator: ", ")
        let script = """
        tell application "/System/Applications/Utilities/Terminal.app"
            launch
            set placements to {\(placements)}
            set createdWindows to {}
            set createdIDs to {}
            repeat with placement in placements
                set newTab to do script ""
                set newWindow to window id (id of front window)
                set end of createdWindows to newWindow
                set end of createdIDs to id of newWindow
                set font size of newTab to (font size of newTab) + \(max(4, zoomSteps) * 2)
                set targetBounds to contents of placement
                set bounds of newWindow to targetBounds
                -- Terminal fits whole character cells. Shrink any outward rounding.
                repeat 12 times
                    set actualBounds to bounds of newWindow
                    set tooWide to item 3 of actualBounds > item 3 of targetBounds
                    set tooTall to item 4 of actualBounds > item 4 of targetBounds
                    if not tooWide and not tooTall then exit repeat
                    if tooWide then set number of columns of newTab to (number of columns of newTab) - 1
                    if tooTall then set number of rows of newTab to (number of rows of newTab) - 1
                end repeat
                if tooWide or tooTall then error "Terminal window cannot fit on this display. Reduce its profile font size."

            end repeat
            activate
            repeat with newWindow in createdWindows
                set index of newWindow to 1
            end repeat
            set index of item 1 of createdWindows to 1
        end tell
        set AppleScript's text item delimiters to ","
        return createdIDs as text
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        DirectoryScriptLifecycle.shared.track(process)
        defer { DirectoryScriptLifecycle.shared.untrack(process) }
        guard finished.wait(timeout: .now() + 60) == .success else {
            process.terminate()
            throw NSError(domain: "QuickTerminal", code: 1, userInfo: [NSLocalizedDescriptionKey: "Terminal automation timed out. Check System Settings → Privacy & Security → Automation."])
        }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "QuickTerminal", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
