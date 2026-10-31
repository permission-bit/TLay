import Foundation
import CoreGraphics

enum LayoutPreset: String, Codable, CaseIterable {
    case grid, columns, focus
    var capacity: Int { self == .grid ? 4 : self == .columns ? 2 : 1 }
    func rectangles(in screen: CGRect, gap: Double) -> [CGRect] {
        let columns = self == .focus ? 1 : 2
        let rows = self == .grid ? 2 : 1
        let spacing = min(max(0, gap), min(screen.width, screen.height) / 8)
        let width = (screen.width - spacing * Double(columns + 1)) / Double(columns)
        let height = (screen.height - spacing * Double(rows + 1)) / Double(rows)
        return (0..<capacity).map { index in
            CGRect(x: screen.minX + spacing + Double(index % columns) * (width + spacing),
                   y: screen.minY + spacing + Double(index / columns) * (height + spacing),
                   width: width, height: height)
        }
    }
}

struct Preferences: Codable, Equatable {
    var language = "en"
    var completedWelcome = false
    var preset = LayoutPreset.grid
    var gap = 12.0
    var selectedApps = ["com.apple.Terminal", "com.googlecode.iterm2"]
    var automatic = true
    var enlargeText = true
    var zoomSteps = 4
    var groupByDirectory = false

    init() {}
    enum CodingKeys: String, CodingKey {
        case language, completedWelcome, preset, gap, selectedApps, automatic, enlargeText, zoomSteps, groupByDirectory
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? "en"
        completedWelcome = try values.decodeIfPresent(Bool.self, forKey: .completedWelcome) ?? false
        preset = try values.decodeIfPresent(LayoutPreset.self, forKey: .preset) ?? .grid
        gap = try values.decodeIfPresent(Double.self, forKey: .gap) ?? 12
        selectedApps = try values.decodeIfPresent([String].self, forKey: .selectedApps) ?? selectedApps
        automatic = try values.decodeIfPresent(Bool.self, forKey: .automatic) ?? true
        enlargeText = try values.decodeIfPresent(Bool.self, forKey: .enlargeText) ?? true
        zoomSteps = try values.decodeIfPresent(Int.self, forKey: .zoomSteps) ?? 4
        groupByDirectory = try values.decodeIfPresent(Bool.self, forKey: .groupByDirectory) ?? false
    }
    func validated() -> Preferences {
        var copy = self
        if !Language.all.contains(where: { $0.id == language }) { copy.language = "en" }
        copy.gap = gap.isFinite ? min(32, max(0, gap)) : 12
        copy.zoomSteps = min(8, max(0, zoomSteps))
        copy.selectedApps = selectedApps.filter { id in AppTarget.all.contains { $0.id == id } }
        return copy
    }
}

struct ZoomLedger: Codable {
    var applied: [String: Int] = [:]
    func remaining(for id: String, target: Int) -> Int { max(0, target - (applied[id] ?? 0)) }
    mutating func didZoom(_ id: String) { applied[id, default: 0] += 1 }
}

struct AppTarget: Identifiable {
    let id: String
    let name: String
    let symbol: String
    static let all = [
        AppTarget(id: "com.apple.Terminal", name: "Terminal", symbol: "terminal"),
        AppTarget(id: "com.googlecode.iterm2", name: "iTerm2", symbol: "chevron.left.forwardslash.chevron.right"),
        AppTarget(id: "com.apple.Safari", name: "Safari", symbol: "safari"),
        AppTarget(id: "com.google.Chrome", name: "Google Chrome", symbol: "globe")
    ]
}

struct PreferencesStore {
    let directory: URL
    var file: URL { directory.appendingPathComponent("preferences.json") }
    static var standard: PreferencesStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return PreferencesStore(directory: base.appendingPathComponent("com.rastafari.terminallayout"))
    }
    func load() throws -> Preferences {
        guard FileManager.default.fileExists(atPath: file.path) else { return Preferences() }
        return try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: file)).validated()
    }
    func save(_ preferences: Preferences) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preferences.validated()).write(to: file, options: .atomic)
    }
}

enum PromptConfiguration {
    static let start = "# >>> terminal-layout prompt >>>"
    static let end = "# <<< terminal-layout prompt <<<"
    static let block = """
    # >>> terminal-layout prompt >>>
    PROMPT='%F{yellow}❯%f '
    RPROMPT='%F{cyan}%n@%m%f %F{blue}%1~%f'
    # <<< terminal-layout prompt <<<
    """
    // Exact output of the original Rust CLI. Never remove an arbitrary precmd hook.
    static let legacy = """
    # terminal-layout: kompakter Prompt
    # Die Eingabe beginnt immer links; Benutzer, Rechner und Ordner stehen rechts.
    autoload -Uz colors && colors
    setopt prompt_subst
    precmd() {
      PROMPT="%F{yellow}❯%f "
      RPROMPT="%F{cyan}%n@%m%f %F{blue}%1~%f"
    }
    PROMPT='%F{yellow}❯%f '
    RPROMPT='%F{cyan}%n@%m%f %F{blue}%1~%f'
    """
    static let earlierLegacy = """
    # terminal-layout: kompakter Prompt
    # Der Ordnername bleibt sichtbar, sehr lange Pfade werden abgekürzt.
    autoload -Uz colors && colors
    setopt prompt_subst
    precmd() {
      PROMPT="%F{cyan}%n@%m%f %F{blue}%~%f %F{yellow}❯%f "
    }
    PROMPT='%F{cyan}%n@%m%f %F{blue}%~%f %F{yellow}❯%f '
    """
    enum EditError: Error { case incompleteManagedBlock, unexpectedFileType }
    static func removingManagedPrompt(from source: String) throws -> String {
        var text = source
        while let begin = text.range(of: start) {
            guard let finish = text.range(of: end, range: begin.upperBound..<text.endIndex) else {
                throw EditError.incompleteManagedBlock
            }
            guard (begin.lowerBound == text.startIndex || text[text.index(before: begin.lowerBound)] == "\n"),
                  (finish.upperBound == text.endIndex || text[finish.upperBound] == "\n") else {
                throw EditError.incompleteManagedBlock
            }
            var upper = finish.upperBound
            if upper < text.endIndex && text[upper] == "\n" { upper = text.index(after: upper) }
            text.removeSubrange(begin.lowerBound..<upper)
        }
        if text.contains(end) { throw EditError.incompleteManagedBlock }
        for legacyBlock in [legacy, earlierLegacy] {
            text = text.replacingOccurrences(of: legacyBlock + "\n", with: "")
            if text.hasSuffix(legacyBlock) { text.removeLast(legacyBlock.count) }
        }
        return text
    }
    static func installing(in source: String) throws -> String {
        let clean = try removingManagedPrompt(from: source)
        return clean + (clean.isEmpty || clean.hasSuffix("\n") ? "" : "\n") + block + "\n"
    }
    static func shellFile(home: URL, environment: [String: String]) -> URL {
        if let directory = environment["ZDOTDIR"], directory.hasPrefix("/") {
            return URL(fileURLWithPath: directory).appendingPathComponent(".zshrc")
        }
        return home.appendingPathComponent(".zshrc")
    }
    static func read(_ url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        let resolved = url.resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw EditError.unexpectedFileType
        }
        return try String(contentsOf: resolved, encoding: .utf8)
    }
    // Keep user edits made after installation and back up every file before changing it.
    static func update(file: URL, backupDirectory: URL, install: Bool) throws {
        let resolved = file.resolvingSymlinksInPath()
        let exists = FileManager.default.fileExists(atPath: resolved.path)
        let source = try read(resolved)
        let updated = try install ? installing(in: source) : removingManagedPrompt(from: source)
        guard source != updated else { return }
        var mode: NSNumber?
        if exists {
            let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw EditError.unexpectedFileType
            }
            mode = attributes[.posixPermissions] as? NSNumber
            try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let backup = backupDirectory.appendingPathComponent("zshrc-\(UUID().uuidString).backup")
            try Data(source.utf8).write(to: backup, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        try Data(updated.utf8).write(to: resolved, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: mode ?? NSNumber(value: 0o600)],
                                             ofItemAtPath: resolved.path)
    }
}
