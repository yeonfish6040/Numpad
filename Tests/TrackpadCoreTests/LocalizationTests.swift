import Foundation
import XCTest
@testable import TrackpadCore

final class LocalizationTests: XCTestCase {
    func testEnglishIsTheDefaultAndLanguageChoicePersists() throws {
        let suite = "Numpad.LocalizationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["ko-KR"], forKey: "AppleLanguages")
        XCTAssertEqual(AppLanguage.load(from: defaults), .english)
        defaults.set("ko", forKey: "appLanguage")
        XCTAssertEqual(AppLanguage.load(from: defaults), .korean)
        defaults.set("unsupported", forKey: "appLanguage")
        XCTAssertEqual(AppLanguage.load(from: defaults), .english)
    }

    func testPackagedCatalogsHaveMatchingKeysAndTranslateAllLanguages() throws {
        func catalog(_ language: AppLanguage) throws -> [String: String] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: language.rawValue, withExtension: "json"))
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([String: String].self, from: data)
        }
        let english = try catalog(.english)
        XCTAssertFalse(english.isEmpty)
        for language in AppLanguage.allCases where language != .english {
            let translated = try catalog(language)
            XCTAssertEqual(Set(english.keys), Set(translated.keys), "Key mismatch for \(language.rawValue)")
            for key in english.keys {
                XCTAssertTrue(key.split(separator: ".").count >= 3, "Catalog ID must be dotted: \(key)")
                XCTAssertEqual(AppLocalization.text(key), english[key])
                XCTAssertEqual(AppLocalization.text(key, language: language), translated[key])
                XCTAssertFalse(try XCTUnwrap(translated[key]).isEmpty, "Empty value for \(key) in \(language.rawValue)")
                for placeholder in ["%d", "%@"] {
                    XCTAssertEqual(english[key]?.components(separatedBy: placeholder).count,
                                   translated[key]?.components(separatedBy: placeholder).count,
                                   "Format mismatch for \(key) in \(language.rawValue)")
                }
            }
        }
        XCTAssertEqual(AppLocalization.text("app.ui.settings"), "Settings…")
        XCTAssertEqual(AppLocalization.text("app.ui.settings", language: .korean), "설정…")
        XCTAssertEqual(AppLocalization.text("app.ui.settings", language: .japanese), "設定…")
        XCTAssertEqual(AppLocalization.text("Unknown key", language: .korean), "Unknown key")
    }

    func testExistingStatusCanBeRenderedInEitherLanguageWithFingerCounts() {
        let status = LocalizedMessage("app.ui.calibrating_with_count_fingers", count: 4)
        XCTAssertEqual(status.text(language: .english), "Calibrating with 4 fingers")
        XCTAssertEqual(status.text(language: .korean), "4손가락을 따라 보정 중")
        XCTAssertEqual(status.text(language: .japanese), "4本指でキャリブレーション中")
        let error = LocalizedMessage(CalibrationError.tooClose.localizedDescription)
        XCTAssertEqual(error.text(language: .english), "Move your fingers a little farther apart.")
        XCTAssertEqual(error.text(language: .korean), "손가락 사이를 조금 더 벌려 주세요.")
        XCTAssertEqual(error.text(language: .japanese), "指をもう少し広げてください。")
    }
}
