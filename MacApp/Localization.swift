import Foundation

struct Language: Identifiable {
    let id: String
    let name: String
    static let all = [
        Language(id: "en", name: "English"),
        Language(id: "de", name: "Deutsch"),
        Language(id: "es", name: "Español"),
        Language(id: "fr", name: "Français"),
        Language(id: "it", name: "Italiano"),
        Language(id: "pt-BR", name: "Português (Brasil)"),
        Language(id: "ru", name: "Русский"),
        Language(id: "hi", name: "हिन्दी"),
        Language(id: "ar", name: "العربية"),
        Language(id: "zh-Hans", name: "简体中文"),
        Language(id: "ja", name: "日本語"),
        Language(id: "ko", name: "한국어")
    ]
}

struct Translations {
    let table: [String: [String: String]]
    init(url: URL) throws {
        var result = try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: url))
        let supplement = url.deletingLastPathComponent().appendingPathComponent("AutomationTranslations.json")
        let extra = try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: supplement))
        for (language, values) in extra {
            result[language, default: [:]].merge(values) { _, new in new }
        }
        table = result
    }
    static let bundled: Translations = {
        guard let url = Bundle.main.url(forResource: "Translations", withExtension: "json"),
              let translations = try? Translations(url: url) else {
            fatalError("The app bundle is missing Translations.json. Rebuild with build-app.sh.")
        }
        return translations
    }()
    func text(_ key: String, language: String) -> String {
        table[language]?[key] ?? table["en"]?[key] ?? key
    }
}
