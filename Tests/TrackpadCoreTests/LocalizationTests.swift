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
            let url = try XCTUnwrap(Bundle.module.url(forResource: "Localizable", withExtension: "strings",
                                                    subdirectory: "\(language.rawValue).lproj"))
            let data = try Data(contentsOf: url)
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        let english = try catalog(.english)
        XCTAssertFalse(english.isEmpty)
        for language in AppLanguage.allCases where language != .english {
            let translated = try catalog(language)
            XCTAssertEqual(Set(english.keys), Set(translated.keys), "Key mismatch for \(language.rawValue)")
            for key in english.keys {
                XCTAssertEqual(AppLocalization.text(key), english[key])
                XCTAssertEqual(AppLocalization.text(key, language: language), translated[key])
                XCTAssertFalse(try XCTUnwrap(translated[key]).isEmpty, "Empty value for \(key) in \(language.rawValue)")
                XCTAssertEqual(key.components(separatedBy: "%d").count,
                               translated[key]?.components(separatedBy: "%d").count,
                               "Format mismatch for \(key) in \(language.rawValue)")
            }
        }
        XCTAssertEqual(AppLocalization.text("Settings…", language: .korean), "설정…")
        XCTAssertEqual(AppLocalization.text("Settings…", language: .japanese), "設定…")
        XCTAssertEqual(AppLocalization.text("Unknown key", language: .korean), "Unknown key")
    }

    func testExistingStatusCanBeRenderedInEitherLanguageWithFingerCounts() {
        let status = LocalizedMessage("Calibrating with %d fingers", count: 4)
        XCTAssertEqual(status.text(language: .english), "Calibrating with 4 fingers")
        XCTAssertEqual(status.text(language: .korean), "4손가락을 따라 보정 중")
        XCTAssertEqual(status.text(language: .japanese), "4本指でキャリブレーション中")
        let error = LocalizedMessage(CalibrationError.tooClose.localizedDescription)
        XCTAssertEqual(error.text(language: .english), "Move your fingers a little farther apart.")
        XCTAssertEqual(error.text(language: .korean), "손가락 사이를 조금 더 벌려 주세요.")
        XCTAssertEqual(error.text(language: .japanese), "指をもう少し広げてください。")
    }
}
