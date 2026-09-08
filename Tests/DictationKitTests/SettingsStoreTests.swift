import XCTest
@testable import DictationKit

final class SettingsStoreTests: XCTestCase {

    /// A throwaway defaults domain so tests don't touch the real app preferences.
    private func scratchDefaults() -> UserDefaults {
        let suite = "SettingsStoreTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    func testLoadReturnsDefaultsWhenNothingStored() {
        let store = SettingsStore(defaults: scratchDefaults())
        XCTAssertEqual(store.load(), Settings())
    }

    func testNewDefaultsKeepCurrentCueVolumeAndEnableLiveNormalization() {
        let settings = Settings()
        XCTAssertEqual(settings.cueVolume, .full)
        XCTAssertTrue(settings.normalizeLiveDictation)
    }

    func testLegacyJSONKeepsOldFieldsAndDefaultsNewFields() throws {
        let defaults = scratchDefaults()
        let legacy = #"{"activationKey":{"keyCode":55,"deviceMask":8},"mode":"toggle","restoreClipboard":false}"#
        defaults.set(Data(legacy.utf8), forKey: "settings.v1")

        let loaded = SettingsStore(defaults: defaults).load()

        XCTAssertEqual(loaded.activationKey, .leftCommand)
        XCTAssertEqual(loaded.mode, .toggle)
        XCTAssertFalse(loaded.restoreClipboard)
        XCTAssertEqual(loaded.cueVolume, .full)
        XCTAssertTrue(loaded.normalizeLiveDictation)
        XCTAssertEqual(loaded.statusDotColors, .default)
    }

    func testEveryCueVolumeRoundTrips() {
        for volume in CueVolume.allCases {
            let store = SettingsStore(defaults: scratchDefaults())
            store.save(Settings(cueVolume: volume, normalizeLiveDictation: false))
            XCTAssertEqual(store.load().cueVolume, volume)
            XCTAssertFalse(store.load().normalizeLiveDictation)
        }
    }

    func testSavedSettingsRoundTrip() {
        let store = SettingsStore(defaults: scratchDefaults())
        let custom = Settings(activationKey: .leftCommand, mode: .toggle, restoreClipboard: false)
        store.save(custom)
        XCTAssertEqual(store.load(), custom)
    }

    func testCustomDotColorsRoundTrip() {
        let store = SettingsStore(defaults: scratchDefaults())
        var colors = StatusDotColors.default
        colors.recording = IconColor(hex: "#123456")!
        colors.processing = IconColor(hex: "ABCDEF")!
        colors.success = IconColor(hex: "#010203")!
        colors.failure = IconColor(hex: "#FEDCBA")!
        store.save(Settings(statusDotColors: colors))
        XCTAssertEqual(store.load().statusDotColors, colors)
    }

    func testHexColorParsesAndFormatsCanonicalValue() {
        XCTAssertEqual(IconColor(hex: " #12aBcF ")?.hex, "#12ABCF")
        XCTAssertNil(IconColor(hex: "#12345"))
        XCTAssertNil(IconColor(hex: "#GG0000"))
    }

    func testSettingsSurviveANewStoreOnTheSameDefaults() {
        let defaults = scratchDefaults()
        let custom = Settings(activationKey: .rightControl, mode: .toggle, restoreClipboard: false)
        SettingsStore(defaults: defaults).save(custom)

        // A fresh store over the same domain models an app restart.
        XCTAssertEqual(SettingsStore(defaults: defaults).load(), custom)
    }

    func testEachFieldPersistsIndependently() {
        let store = SettingsStore(defaults: scratchDefaults())
        store.save(Settings(activationKey: .leftOption, mode: .pushToTalk, restoreClipboard: false))
        let loaded = store.load()
        XCTAssertEqual(loaded.activationKey, .leftOption)
        XCTAssertEqual(loaded.mode, .pushToTalk)
        XCTAssertFalse(loaded.restoreClipboard)
    }

    func testCorruptDataFallsBackToDefaults() {
        let defaults = scratchDefaults()
        defaults.set(Data("not json".utf8), forKey: "settings.v1")
        XCTAssertEqual(SettingsStore(defaults: defaults).load(), Settings(),
                       "undecodable stored data must not brick the app")
    }
}
