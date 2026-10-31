import Foundation
import Darwin

final class DirectoryScriptLifecycle: @unchecked Sendable {
    static let shared = DirectoryScriptLifecycle()
    private let lock = NSLock()
    private var processes: [Int32: Process] = [:]
    func track(_ process: Process) {
        lock.lock()
        processes[process.processIdentifier] = process
        lock.unlock()
    }
    func untrack(_ process: Process) {
        lock.lock()
        processes.removeValue(forKey: process.processIdentifier)
        lock.unlock()
    }
    func terminate() {
        lock.lock()
        let running = Array(processes.values)
        lock.unlock()
        for process in running where process.isRunning { process.terminate() }
    }
}

struct DirectoryResult {
    var paths: [String: String] = [:]
    var accessIssue = false
}

struct TerminalHint: Decodable {
    let app: String
    let number: Int
    let title: String
    let tty: String
    let bounds: [Double]
    var frame: CGRect? {
        guard bounds.count == 4 else { return nil }
        return CGRect(x: bounds[0], y: bounds[1], width: bounds[2], height: bounds[3])
    }
}

struct DirectoryDiscovery {
    private var denied = false
    mutating func reset() { denied = false }

    mutating func paths(for windows: [ManagedWindow], processes: [ManagedProcess]) -> DirectoryResult {
        var result = DirectoryResult()
        for window in windows where window.isTerminal {
            if let path = window.directory { result.paths[window.id] = path }
        }
        let missing = windows.filter { $0.isTerminal && $0.directory == nil }
        guard !missing.isEmpty else { return result }
        guard !denied else { result.accessIssue = true; return result }
        let ids = Array(Set(missing.map(\.app))).sorted()
        do {
            let hints = try terminalHints(ids: ids)
            let directories = ProcessDirectories.forTTYs(Set(hints.map(\.tty)))
            for window in missing {
                let appHints = hints.filter { $0.app == window.app }
                let numbered = appHints.filter { window.number != nil && $0.number == window.number }
                let byBounds = appHints.filter { hint in
                    guard let rect = hint.frame else { return false }
                    return abs(rect.minX - window.frame.minX) < 3 && abs(rect.minY - window.frame.minY) < 3
                        && abs(rect.width - window.frame.width) < 3 && abs(rect.height - window.frame.height) < 3
                }
                let possible = numbered.isEmpty ? byBounds : numbered
                // Never guess a directory from a shortened window title.
                if possible.count == 1, let path = directories[possible[0].tty] {
                    result.paths[window.id] = path
                }
            }
        } catch {
            denied = true
            result.accessIssue = true
        }
        return result
    }

    private func terminalHints(ids: [String]) throws -> [TerminalHint] {
        let encoded = String(data: try JSONEncoder().encode(ids), encoding: .utf8)!
        let script = """
        function run() {
            var ids = \(encoded);
            var output = [];
            ids.forEach(function(id) {
                var app = Application(id);
                if (!app.running()) return;
                app.windows().forEach(function(win) {
                    var tab = id === "com.apple.Terminal" ? win.selectedTab() : win.currentSession();
                    var rect = win.bounds();
                    var bounds = Array.isArray(rect)
                        ? [rect[0], rect[1], rect[2] - rect[0], rect[3] - rect[1]]
                        : [rect.x, rect.y, rect.width, rect.height];
                    output.push({app: id, number: win.id(), title: win.name(), tty: tab.tty(), bounds: bounds});
                });
            });
            return JSON.stringify(output);
        }
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-l", "JavaScript", "-e", script]
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        let finished = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in finished.signal() }
        try task.run()
        DirectoryScriptLifecycle.shared.track(task)
        defer { DirectoryScriptLifecycle.shared.untrack(task) }
        let deadline = Date().addingTimeInterval(8)
        while finished.wait(timeout: .now() + 0.2) != .success {
            if Task.isCancelled || Date() >= deadline {
                task.terminate()
                throw NSError(domain: "TerminalDirectory", code: 1)
            }
        }
        guard task.terminationStatus == 0 else { throw NSError(domain: "TerminalDirectory", code: 2) }
        return try JSONDecoder().decode([TerminalHint].self, from: stdout.fileHandleForReading.readDataToEndOfFile())
    }
}

enum ProcessDirectories {
    // Public libproc APIs. Only inspect the current user's shells on the requested TTYs.
    // This reads process metadata and the local working directory, never terminal contents.
    static func forTTYs(_ ttys: Set<String>) -> [String: String] {
        var devices: [UInt32: String] = [:]
        for tty in ttys where tty.hasPrefix("/dev/tty") {
            var info = stat()
            if stat(tty, &info) == 0 { devices[UInt32(bitPattern: info.st_rdev)] = tty }
        }
        guard !devices.isEmpty else { return [:] }
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let capacity = Int32(pids.count * MemoryLayout<pid_t>.size)
        let total = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, capacity) }
        guard total > 0 else { return [:] }
        var found: [String: (UInt64, String)] = [:]
        for pid in pids.prefix(min(Int(total), pids.count)) where pid > 0 {
            var process = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &process, Int32(MemoryLayout.size(ofValue: process))) > 0,
                  process.pbi_uid == getuid(), let tty = devices[process.e_tdev] else { continue }
            let name = withUnsafePointer(to: &process.pbi_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
            }
            guard ["zsh", "bash", "fish", "sh", "dash", "ksh", "nu", "xonsh"].contains(name) else { continue }
            var vnode = proc_vnodepathinfo()
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, Int32(MemoryLayout.size(ofValue: vnode))) > 0 else { continue }
            let path = withUnsafePointer(to: &vnode.pvi_cdir.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard path.hasPrefix("/") else { continue }
            let time = process.pbi_start_tvsec * 1_000_000 + process.pbi_start_tvusec
            if found[tty] == nil || found[tty]!.0 < time { found[tty] = (time, path) }
        }
        return found.mapValues(\.1)
    }
}
