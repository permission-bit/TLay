import AppKit
import SwiftUI

// Render only our own UI; this does not capture the user's desktop or change their settings.
@main
enum Preview {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalLayoutPreview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = LayoutModel(store: PreferencesStore(directory: root),
                                shellFile: root.appendingPathComponent(".zshrc"), monitoringEnabled: false)
        model.showWelcome = false
        model.preferences.language = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "en"
        let welcome = CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "welcome"
        let folders = CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "folders"
        if folders {
            model.observedWindows = [
                ManagedWindow(id: "1", app: "com.apple.Terminal", pid: 0, element: nil, number: nil,
                              title: "Terminal Layout — zsh", frame: .zero, directory: "/Projects/TerminalLayout"),
                ManagedWindow(id: "2", app: "com.googlecode.iterm2", pid: 0, element: nil, number: nil,
                              title: "Build — cargo", frame: .zero, directory: "/Projects/TerminalLayout"),
                ManagedWindow(id: "3", app: "com.apple.Terminal", pid: 0, element: nil, number: nil,
                              title: "Website — zsh", frame: .zero, directory: "/Projects/Website")
            ]
        }
        let content = Group {
            if welcome { WelcomeView() }
            else if folders { FolderOverview() }
            else { ContentView() }
        }.environmentObject(model)
            .environment(\.locale, Locale(identifier: model.preferences.language))
            .environment(\.layoutDirection, model.isRTL ? .rightToLeft : .leftToRight)
            .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: content)
        let size = welcome ? NSSize(width: 502, height: 500) : folders ? NSSize(width: 640, height: 560)
            : NSSize(width: 800, height: 780)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        window.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw NSError(domain: "Preview", code: 1)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Preview", code: 2)
        }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("Rendered \(model.preferences.language) preview.")
    }
}
