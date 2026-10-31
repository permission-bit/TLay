import Foundation
import CoreGraphics

@main
enum CoreTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !condition() { throw Failure(message: message) }
    }
    struct Failure: Error { let message: String }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalLayoutTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let user = "# My shell\nexport MY_WORK=unchanged\nprecmd() { print custom }\n"
        let installed = try PromptConfiguration.installing(in: user)
        try check(try PromptConfiguration.installing(in: installed) == installed, "Installation must be idempotent")
        try check(try PromptConfiguration.removingManagedPrompt(from: installed) == user, "Uninstall preserves user content")
        let laterEdit = "\n# Added after installation\nalias mycommand='ls -la'\n"
        try check(try PromptConfiguration.removingManagedPrompt(from: installed + laterEdit) == user + laterEdit,
                  "Reset preserves edits made after installation")
        let old = user + PromptConfiguration.legacy + "\n" + PromptConfiguration.legacy + "\n"
        try check(try PromptConfiguration.removingManagedPrompt(from: old) == user, "Remove repeated CLI installations")
        try check(try PromptConfiguration.removingManagedPrompt(from: user + PromptConfiguration.earlierLegacy + "\n") == user,
                  "Remove the first CLI version")
        try check(try PromptConfiguration.removingManagedPrompt(from: user + "\n" + PromptConfiguration.block + "\n") == user + "\n",
                  "Remove the previous GUI prompt")
        var refused = false
        do { _ = try PromptConfiguration.removingManagedPrompt(from: user + PromptConfiguration.start) }
        catch { refused = true }
        try check(refused, "Incomplete markers must not cause deletion of user content")

        let shell = root.appendingPathComponent(".zshrc")
        let backups = root.appendingPathComponent("Backups")
        try Data(user.utf8).write(to: shell)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: shell.path)
        let link = root.appendingPathComponent("zshrc-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: shell)
        try PromptConfiguration.update(file: link, backupDirectory: backups, install: true)
        try check(try String(contentsOf: shell, encoding: .utf8) == installed, "Update resolves symlink target")
        try check(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == shell.path, "Preserve symlink")
        let attributes = try FileManager.default.attributesOfItem(atPath: shell.path)
        try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o640, "Preserve shell file permissions")
        try PromptConfiguration.update(file: link, backupDirectory: backups, install: false)
        try check(try String(contentsOf: shell, encoding: .utf8) == user, "Reset restores original shell settings")
        let backupFiles = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        try check(backupFiles.count == 2, "Every modification must have a backup")
        for backup in backupFiles {
            let attrs = try FileManager.default.attributesOfItem(atPath: backup.path)
            try check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Shell backups must be private")
        }
        let missing = root.appendingPathComponent("missing-zshrc")
        try PromptConfiguration.update(file: missing, backupDirectory: backups, install: false)
        try check(!FileManager.default.fileExists(atPath: missing.path), "Reset must not create a missing .zshrc")

        let store = PreferencesStore(directory: root.appendingPathComponent("Settings"))
        try check(try store.load() == Preferences(), "First launch uses factory defaults")
        let oldSettings = Data(#"{"language":"de","completedWelcome":true,"preset":"columns","gap":8,"selectedApps":["com.apple.Terminal"]}"#.utf8)
        let migrated = try JSONDecoder().decode(Preferences.self, from: oldSettings)
        try check(migrated.automatic && migrated.enlargeText && migrated.zoomSteps == 4
                  && !migrated.groupByDirectory && migrated.language == "de",
                  "Existing settings migrate without losing language or disabling the new defaults")
        var selected = Preferences()
        selected.language = "ja"
        selected.preset = .columns
        selected.gap = 26
        selected.completedWelcome = true
        selected.selectedApps = ["com.apple.Safari"]
        try store.save(selected)
        try check(try store.load() == selected, "Settings and language survive relaunch")
        try store.save(Preferences())
        try check(try store.load() == Preferences(), "All settings return to factory defaults")
        try check(try store.load().language == "en" && !store.load().completedWelcome, "Reset returns to English and onboarding")
        selected.language = "unknown"
        selected.gap = -100
        selected.selectedApps = ["unknown"]
        try check(selected.validated().language == "en" && selected.validated().gap == 0
                  && selected.validated().selectedApps.isEmpty, "Validate settings on disk")

        let screen = CGRect(x: -1440, y: -300, width: 1440, height: 875)
        for preset in LayoutPreset.allCases {
            for gap in [0.0, 12, 32] {
                let rectangles = preset.rectangles(in: screen, gap: gap)
                try check(rectangles.count == preset.capacity, "Preset capacity")
                for rect in rectangles {
                    try check(screen.contains(rect), "Layout respects screen bounds and negative origins")
                }
                for i in rectangles.indices {
                    for j in rectangles.indices where j > i {
                        try check(!rectangles[i].intersects(rectangles[j]), "Windows must not overlap")
                    }
                }
                let last = rectangles.last!
                try check(abs(last.maxX - (screen.maxX - gap)) < 0.01
                          && abs(last.maxY - (screen.maxY - gap)) < 0.01, "Symmetrical screen spacing")
            }
        }

        let resource = URL(fileURLWithPath: CommandLine.arguments[1])
        let translations = try Translations(url: resource)
        let expected = Set(translations.table["en"]!.keys)
        try check(expected.contains("background") && expected.contains("missionHint"), "Background UI resources must be bundled")
        try check(Set(translations.table.keys) == Set(Language.all.map(\.id)), "Translation coverage for all languages")
        for language in Language.all {
            let strings = translations.table[language.id]!
            try check(Set(strings.keys) == expected, "Missing translated keys in \(language.id)")
            try check(strings.values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                      "Empty translation in \(language.id)")
        }
        try check(translations.text("reset", language: "unknown") == translations.text("reset", language: "en"),
                  "Unsupported languages fall back to English")
        print("Passed \(checks) checks: prompt migration, safe reset, backups, persistence, layout geometry and 12 languages.")
    }
}
