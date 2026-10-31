import AppKit
import Foundation

@main
enum ModelTests {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalLayoutModel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PreferencesStore(directory: root.appendingPathComponent("Settings"))
        let shell = root.appendingPathComponent(".zshrc")
        let user = "# keep my shell\nexport MY_CONFIG=safe\n"
        try Data((user + PromptConfiguration.legacy + "\n").utf8).write(to: shell)
        let model = LayoutModel(store: store, shellFile: shell, monitoringEnabled: false)
        precondition(model.showWelcome && model.preferences.language == "en")
        precondition(model.promptInstalled)
        model.preferences.language = "ar"
        model.preferences.completedWelcome = true
        model.preferences.preset = .focus
        model.preferences.gap = 30
        model.preferences.selectedApps = ["com.apple.Safari"]
        let savedLanguage = try store.load().language
        precondition(savedLanguage == "ar")
        let reopened = LayoutModel(store: store, shellFile: shell, monitoringEnabled: false)
        precondition(!reopened.showWelcome && reopened.isRTL)
        model.factoryReset()
        precondition(model.preferences == Preferences())
        precondition(model.showWelcome && !model.promptInstalled && model.statusKey == "resetDone")
        let resetShell = try String(contentsOf: shell, encoding: .utf8)
        precondition(resetShell == user)
        let savedDefaults = try store.load()
        precondition(savedDefaults == Preferences())

        model.changePrompt(install: true)
        precondition(model.promptInstalled && model.statusKey == "newTerminal")
        model.changePrompt(install: false)
        precondition(!model.promptInstalled && model.statusKey == "promptRemoved")
        let afterRemoval = try String(contentsOf: shell, encoding: .utf8)
        precondition(afterRemoval == user)

        model.preferences.language = "ja"
        try Data((user + PromptConfiguration.start + "\n").utf8).write(to: shell)
        model.factoryReset()
        precondition(model.statusKey == "error")
        precondition(model.preferences.language == "ja")
        let incomplete = try String(contentsOf: shell, encoding: .utf8)
        precondition(incomplete == user + PromptConfiguration.start + "\n")
        print("Passed model integration: first launch, language persistence, RTL, factory reset, legacy migration and failure handling.")
    }
}
