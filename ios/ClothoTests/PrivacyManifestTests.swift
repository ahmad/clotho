import XCTest

/// Fails if the app or an extension loses its privacy manifest, or a manifest drops an entry it needs. The
/// authoritative check is ios/scripts/check-privacy.py, which compares each bundle's `nm -u` imports with its
/// manifest; this one only reads what the built bundles carry.
final class PrivacyManifestTests: XCTestCase {
    private static let fileTimestamp = "NSPrivacyAccessedAPICategoryFileTimestamp"
    private static let diskSpace = "NSPrivacyAccessedAPICategoryDiskSpace"
    private static let userDefaults = "NSPrivacyAccessedAPICategoryUserDefaults"
    private static let systemBootTime = "NSPrivacyAccessedAPICategorySystemBootTime"

    /// The tests run inside the app (TEST_HOST), so Bundle.main is Clotho.app.
    func testAppHasManifest() throws {
        let apis = try accessedAPIs(in: Bundle.main.bundleURL, name: "Clotho.app")
        XCTAssertEqual(apis[Self.userDefaults], ["CA92.1"])
        XCTAssertEqual(apis[Self.fileTimestamp], ["C617.1", "3B52.1"])
        XCTAssertEqual(apis[Self.diskSpace], ["85F4.1"])
        #if CLOTHO_TAILNET
        XCTAssertEqual(apis[Self.systemBootTime], ["35F9.1"])
        #else
        XCTAssertNil(apis[Self.systemBootTime])
        #endif
    }

    func testExtensionsHaveManifests() throws {
        let plugIns = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        for name in ["ClothoNotify.appex", "ClothoWidget.appex"] {
            let url = plugIns.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(name) isn't in the app")
            let apis = try accessedAPIs(in: url, name: name)
            XCTAssertEqual(apis[Self.fileTimestamp], ["C617.1"], name)
            XCTAssertEqual(apis[Self.diskSpace], ["85F4.1"], name)
            XCTAssertNil(apis[Self.userDefaults], name)
        }
    }

    /// Reads the bundle's PrivacyInfo.xcprivacy, checks it declares no tracking and no collected data, and
    /// returns its required-reason APIs as [category: reasons].
    private func accessedAPIs(in bundle: URL, name: String) throws -> [String: Set<String>] {
        let url = bundle.appendingPathComponent("PrivacyInfo.xcprivacy")
        let data = try XCTUnwrap(try? Data(contentsOf: url), "\(name) has no PrivacyInfo.xcprivacy")
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                                  "\(name)'s manifest isn't a dictionary")
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false, name)
        let collected = try XCTUnwrap(plist["NSPrivacyCollectedDataTypes"] as? [Any], "\(name): no NSPrivacyCollectedDataTypes")
        XCTAssertTrue(collected.isEmpty, "\(name) declares collected data")
        let entries = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]], "\(name): no NSPrivacyAccessedAPITypes")
        var apis: [String: Set<String>] = [:]
        for entry in entries {
            let category = try XCTUnwrap(entry["NSPrivacyAccessedAPIType"] as? String, "\(name): an entry without a category")
            let reasons = try XCTUnwrap(entry["NSPrivacyAccessedAPITypeReasons"] as? [String], "\(name): \(category) without reasons")
            XCTAssertNil(apis[category], "\(name) lists \(category) twice")
            apis[category] = Set(reasons)
        }
        return apis
    }
}
