import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case korean = "ko"
    case japanese = "ja"

    public var name: String {
        switch self {
        case .english: return "English"
        case .korean: return "한국어"
        case .japanese: return "日本語"
        }
    }

    /// An explicit English default, independent of the system's language order.
    public static func load(from defaults: UserDefaults = .standard) -> AppLanguage {
        defaults.string(forKey: "appLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .english
    }
}

public enum AppLocalization {
    private static let catalogs: [AppLanguage: [String: String]] = {
        Dictionary(uniqueKeysWithValues: AppLanguage.allCases.map { ($0, loadCatalog($0)) })
    }()

    public static func text(_ key: String, language: AppLanguage = .english) -> String {
        catalogs[language]?[key] ?? catalogs[.english]?[key] ?? key
    }

    private static func loadCatalog(_ language: AppLanguage) -> [String: String] {
        guard let url = Bundle.module.url(forResource: language.rawValue, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return catalog
    }
}

/// Store a stable catalog ID so existing status text changes language immediately.
public struct LocalizedMessage {
    public let key: String
    public let count: Int?

    public init(_ key: String, count: Int? = nil) {
        self.key = key
        self.count = count
    }

    public func text(language: AppLanguage) -> String {
        let template = AppLocalization.text(key, language: language)
        guard let count else { return template }
        return String(format: template, locale: Locale(identifier: language.rawValue), count)
    }
}
