import IOKit.pwr_mgt
import XCTest
@testable import StayAwakeLib

// MARK: - Parse Sleep Value

final class ParseSleepValueTests: XCTestCase {
    func testTypicalPmsetOutput() {
        let output = """
        System-wide power settings:
        Currently in use:
         standbydelaylow      10800
         sleep                10
         hibernatemode        3
         displaysleep         5
        """
        XCTAssertEqual(parseSleepValue(from: output), 10)
    }

    func testSleepDisabled() {
        let output = """
         sleep                0
         displaysleep         5
        """
        XCTAssertEqual(parseSleepValue(from: output), 0)
    }

    func testNoSleepLine() {
        let output = """
         displaysleep         5
         disksleep            10
        """
        XCTAssertNil(parseSleepValue(from: output))
    }

    func testNonIntegerValue() {
        let output = " sleep                N/A"
        XCTAssertNil(parseSleepValue(from: output))
    }

    func testEmptyOutput() {
        XCTAssertNil(parseSleepValue(from: ""))
    }
}

// MARK: - Config Serialization

final class ConfigTests: XCTestCase {
    private func decode(_ json: String) throws -> StayAwakeConfig {
        try JSONDecoder().decode(StayAwakeConfig.self, from: Data(json.utf8))
    }

    func testDefaultValues() {
        let config = StayAwakeConfig.default
        XCTAssertEqual(config.mode, .on)
        XCTAssertTrue(config.preventScreenLock)
    }

    func testRoundTrip() throws {
        let config = StayAwakeConfig(mode: .off, preventScreenLock: false)
        let decoded = try JSONDecoder().decode(StayAwakeConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.mode, .off)
        XCTAssertFalse(decoded.preventScreenLock)
    }

    func testEmptyObjectUsesDefaults() throws {
        let decoded = try decode("{}")
        XCTAssertEqual(decoded.mode, .on)
        XCTAssertTrue(decoded.preventScreenLock)
        XCTAssertTrue(decoded.malformedKeys.isEmpty, "an absent key is not a malformed key")
    }

    func testLegacyAutoConfigLoadsAsOn() throws {
        let decoded = try decode(#"{"interval": 20, "mode": "auto", "processes": ["node"]}"#)
        XCTAssertEqual(decoded.mode, .on)
        XCTAssertTrue(decoded.preventScreenLock)
    }

    func testLegacyOffConfigStaysOff() throws {
        let decoded = try decode(#"{"interval": 20, "mode": "off", "processes": ["node"]}"#)
        XCTAssertEqual(decoded.mode, .off)
    }

    func testEncodingDropsLegacyKeys() throws {
        let legacy = try decode(#"{"interval": 20, "mode": "off", "processes": ["node"]}"#)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["mode", "preventScreenLock"])
    }

    func testWrongTypedPreventScreenLockFallsBackToSafeValue() throws {
        let decoded = try decode(#"{"preventScreenLock": "yes"}"#)
        XCTAssertFalse(decoded.preventScreenLock, "a value we could not read must not turn screen-lock prevention on")
        XCTAssertEqual(decoded.mode, .on, "an absent key still uses the default")
        XCTAssertEqual(decoded.malformedKeys, ["preventScreenLock"])
    }

    func testMalformedKeyDoesNotDiscardTheRest() throws {
        let decoded = try decode(#"{"mode": "off", "preventScreenLock": "yes"}"#)
        XCTAssertEqual(decoded.mode, .off)
        XCTAssertFalse(decoded.preventScreenLock)
        XCTAssertEqual(decoded.malformedKeys, ["preventScreenLock"])
    }

    func testMalformedModeFallsBackToSafeValueAndKeepsTheRest() throws {
        let decoded = try decode(#"{"mode": 5, "preventScreenLock": false}"#)
        XCTAssertEqual(decoded.mode, .off, "a mode we could not read must not force the Mac awake")
        XCTAssertFalse(decoded.preventScreenLock)
        XCTAssertEqual(decoded.malformedKeys, ["mode"])
    }

    func testNullModeFallsBackToSafeValue() throws {
        let decoded = try decode(#"{"mode": null, "preventScreenLock": false}"#)
        XCTAssertEqual(decoded.mode, .off)
        XCTAssertEqual(decoded.malformedKeys, ["mode"])
    }

    func testEveryMalformedKeyIsReported() throws {
        let decoded = try decode(#"{"mode": 5, "preventScreenLock": "yes"}"#)
        XCTAssertEqual(decoded.mode, .off)
        XCTAssertFalse(decoded.preventScreenLock)
        XCTAssertEqual(decoded.malformedKeys, ["mode", "preventScreenLock"])
    }

    func testMalformedKeysAreNotEncoded() throws {
        let decoded = try decode(#"{"mode": 5}"#)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["mode", "preventScreenLock"])
    }
}

// MARK: - Load Config

final class LoadConfigTests: XCTestCase {
    private var path = ""

    override func setUp() {
        super.setUp()
        path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
        super.tearDown()
    }

    private func write(_ contents: String) throws {
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func testMissingFileUsesDefaults() {
        let result = loadConfig(path: path)
        XCTAssertEqual(result.config.mode, StayAwakeConfig.default.mode)
        XCTAssertNil(result.rejectionReason)
    }

    func testValidFileLoads() throws {
        try write(#"{"mode": "off", "preventScreenLock": false}"#)
        let result = loadConfig(path: path)
        XCTAssertEqual(result.config.mode, .off)
        XCTAssertFalse(result.config.preventScreenLock)
        XCTAssertNil(result.rejectionReason)
    }

    func testMalformedJSONFallsBackToSafeStateAndReportsWhy() throws {
        try write("{ this is not json")
        let result = loadConfig(path: path)
        XCTAssertEqual(result.config.mode, .off, "an unreadable config must not mean \"force the Mac awake\"")
        XCTAssertFalse(result.config.preventScreenLock)
        XCTAssertNotNil(result.rejectionReason)
    }

    func testNonObjectJSONFallsBackToSafeState() throws {
        try write("[1, 2, 3]")
        let result = loadConfig(path: path)
        XCTAssertEqual(result.config.mode, .off)
        XCTAssertNotNil(result.rejectionReason)
    }

    func testSymlinkFallsBackToSafeState() throws {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try #"{"mode": "on"}"#.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target.path)
        defer { try? FileManager.default.removeItem(at: target) }

        let result = loadConfig(path: path)
        XCTAssertEqual(result.config.mode, .off)
        XCTAssertNotNil(result.rejectionReason)
    }

    func testOversizedFileFallsBackToSafeState() throws {
        try write(String(repeating: " ", count: Int(MAX_CONFIG_SIZE) + 1))
        let result = loadConfig(path: path)
        XCTAssertEqual(result.config.mode, .off)
        XCTAssertNotNil(result.rejectionReason)
    }

    func testWrongTypedModeFallsBackToSafeStateAndReportsWhy() throws {
        try write(#"{"mode": 5, "preventScreenLock": false}"#)
        let result = loadConfig(path: path)
        XCTAssertEqual(result.config.mode, .off, "a value we could not read must not mean \"force the Mac awake\"")
        XCTAssertNotNil(result.rejectionReason, "a key we could not read must reach the launch alert")
    }

    func testWrongTypedPreventScreenLockReportsWhyAndKeepsTheReadableKey() throws {
        try write(#"{"mode": "on", "preventScreenLock": "yes"}"#)
        let result = loadConfig(path: path)
        XCTAssertEqual(result.config.mode, .on, "a readable key survives a malformed sibling")
        XCTAssertFalse(result.config.preventScreenLock)
        XCTAssertNotNil(result.rejectionReason)
    }

    func testRejectionReasonNamesTheMalformedKeys() throws {
        try write(#"{"mode": 5, "preventScreenLock": "yes"}"#)
        let reason = try XCTUnwrap(loadConfig(path: path).rejectionReason)
        XCTAssertTrue(reason.contains("mode"))
        XCTAssertTrue(reason.contains("preventScreenLock"))
    }
}

// MARK: - Save Config

final class SaveConfigTests: XCTestCase {
    private var path = ""

    override func setUp() {
        super.setUp()
        path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
        super.tearDown()
    }

    func testWritesRegularFileAndReportsSuccess() throws {
        XCTAssertTrue(saveConfig(StayAwakeConfig(mode: .off, preventScreenLock: false), path: path))
        let result = loadConfig(path: path)
        XCTAssertEqual(result.config.mode, .off)
        XCTAssertFalse(result.config.preventScreenLock)
        let perms = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(perms.int16Value, 0o600)
    }

    func testRefusesSymlinkAndReportsFailure() throws {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try #"{"mode": "on"}"#.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target.path)
        defer { try? FileManager.default.removeItem(at: target) }

        XCTAssertFalse(saveConfig(StayAwakeConfig(mode: .off, preventScreenLock: false), path: path),
                       "a save that never wrote must not report success")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), #"{"mode": "on"}"#)
    }

    func testRefusesDirectoryAndReportsFailure() throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        XCTAssertFalse(saveConfig(.default, path: path))
    }
}

// MARK: - Display Sleep Assertion

final class DisplaySleepAssertionTests: XCTestCase {
    private func ownAssertionTypes() -> [String] {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let all = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        return (all[NSNumber(value: getpid())] ?? []).compactMap { $0[kIOPMAssertionTypeKey] as? String }
    }

    private var holdsDisplayAssertion: Bool {
        ownAssertionTypes().contains(kIOPMAssertionTypePreventUserIdleDisplaySleep)
    }

    func testActivateAndRelease() {
        let assertion = DisplaySleepAssertion()
        XCTAssertFalse(assertion.isActive)

        assertion.setActive(true)
        XCTAssertTrue(assertion.isActive)
        XCTAssertTrue(holdsDisplayAssertion)

        assertion.setActive(false)
        XCTAssertFalse(assertion.isActive)
        XCTAssertFalse(holdsDisplayAssertion)
    }

    func testRepeatedActivateHoldsSingleAssertion() {
        let assertion = DisplaySleepAssertion()
        assertion.setActive(true)
        assertion.setActive(true)
        XCTAssertEqual(ownAssertionTypes().filter { $0 == kIOPMAssertionTypePreventUserIdleDisplaySleep }.count, 1)
        assertion.setActive(false)
        XCTAssertFalse(holdsDisplayAssertion)
    }

    func testDeinitReleases() {
        do {
            let assertion = DisplaySleepAssertion()
            assertion.setActive(true)
            XCTAssertTrue(holdsDisplayAssertion)
        }
        XCTAssertFalse(holdsDisplayAssertion)
    }
}

// MARK: - Mode Decoding

final class ModeTests: XCTestCase {
    func testRemovedAutoModeDecodesAsOn() throws {
        let data = Data("\"auto\"".utf8)
        let mode = try JSONDecoder().decode(Mode.self, from: data)
        XCTAssertEqual(mode, .on)
    }

    func testDecodesOn() throws {
        let data = Data("\"on\"".utf8)
        let mode = try JSONDecoder().decode(Mode.self, from: data)
        XCTAssertEqual(mode, .on)
    }

    func testDecodesOff() throws {
        let data = Data("\"off\"".utf8)
        let mode = try JSONDecoder().decode(Mode.self, from: data)
        XCTAssertEqual(mode, .off)
    }

    func testInvalidModeFallsBackToOff() throws {
        let data = Data("\"banana\"".utf8)
        let mode = try JSONDecoder().decode(Mode.self, from: data)
        XCTAssertEqual(mode, .off)
    }

    func testEmptyModeFallsBackToOff() throws {
        let data = Data("\"\"".utf8)
        let mode = try JSONDecoder().decode(Mode.self, from: data)
        XCTAssertEqual(mode, .off)
    }

    func testModeRoundTrip() throws {
        for mode in [Mode.on, .off] {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(Mode.self, from: data)
            XCTAssertEqual(decoded, mode)
        }
    }
}

// MARK: - Username Validation

final class UsernameValidationTests: XCTestCase {
    func testValidUsername() {
        XCTAssertTrue(isValidUsername("john"))
    }

    func testValidUsernameWithDots() {
        XCTAssertTrue(isValidUsername("john.doe"))
    }

    func testValidUsernameWithUnderscore() {
        XCTAssertTrue(isValidUsername("john_doe"))
    }

    func testValidUsernameWithHyphen() {
        XCTAssertTrue(isValidUsername("john-doe"))
    }

    func testValidUsernameWithDigits() {
        XCTAssertTrue(isValidUsername("user2"))
    }

    func testEmptyRejected() {
        XCTAssertFalse(isValidUsername(""))
    }

    func testSemicolonRejected() {
        XCTAssertFalse(isValidUsername("john;rm -rf /"))
    }

    func testSpaceRejected() {
        XCTAssertFalse(isValidUsername("john doe"))
    }

    func testQuoteRejected() {
        XCTAssertFalse(isValidUsername("john'doe"))
    }

    func testSlashRejected() {
        XCTAssertFalse(isValidUsername("../etc"))
    }
}

// MARK: - Clamp Sleep Value

final class ClampSleepValueTests: XCTestCase {
    func testValueInRange() {
        XCTAssertEqual(clampSleepValue(10), 10)
    }

    func testMinBoundary() {
        XCTAssertEqual(clampSleepValue(1), 1)
    }

    func testMaxBoundary() {
        XCTAssertEqual(clampSleepValue(180), 180)
    }

    func testBelowMinClampsTo1() {
        XCTAssertEqual(clampSleepValue(0), 1)
    }

    func testNegativeClampsTo1() {
        XCTAssertEqual(clampSleepValue(-50), 1)
    }

    func testAboveMaxClampsTo180() {
        XCTAssertEqual(clampSleepValue(999), 180)
    }

    func testJustAboveMax() {
        XCTAssertEqual(clampSleepValue(181), 180)
    }
}

// MARK: - Build Sudoers Rule

final class BuildSudoersRuleTests: XCTestCase {
    func testContainsUsername() {
        let rule = buildSudoersRule(for: "testuser")
        XCTAssertTrue(rule.hasPrefix("testuser "))
    }

    func testUsesRootNotAll() {
        let rule = buildSudoersRule(for: "testuser")
        XCTAssertTrue(rule.contains("ALL=(root)"))
        XCTAssertFalse(rule.contains("ALL=(ALL)"))
    }

    func testNoWildcardInSleepCommands() {
        let rule = buildSudoersRule(for: "testuser")
        XCTAssertFalse(rule.contains("sleep *"))
    }

    func testContainsDigitPatterns() {
        let rule = buildSudoersRule(for: "testuser")
        XCTAssertTrue(rule.contains("sleep [0-9]"))
        XCTAssertTrue(rule.contains("sleep [0-9][0-9]"))
        XCTAssertTrue(rule.contains("sleep [0-9][0-9][0-9]"))
    }

    func testContainsDisablesleepCommands() {
        let rule = buildSudoersRule(for: "testuser")
        XCTAssertTrue(rule.contains("disablesleep 0"))
        XCTAssertTrue(rule.contains("disablesleep 1"))
    }

    func testContainsPmsetGet() {
        let rule = buildSudoersRule(for: "testuser")
        XCTAssertTrue(rule.contains("/usr/bin/pmset -g"))
    }

    func testUsesFullPmsetPath() {
        let rule = buildSudoersRule(for: "testuser")
        XCTAssertTrue(rule.contains("/usr/bin/pmset"))
        XCTAssertFalse(rule.contains(" pmset "))
    }

    func testNOPASSWD() {
        let rule = buildSudoersRule(for: "testuser")
        XCTAssertTrue(rule.contains("NOPASSWD:"))
    }
}

// MARK: - Path Safety

final class PathSafetyTests: XCTestCase {
    func testRegularFileIsValid() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "test".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertTrue(isPathSafeToAccess(tmp.path))
    }

    func testSymlinkIsRejected() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "test".write(to: tmp, atomically: true, encoding: .utf8)
        let link = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tmp)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: tmp)
        }
        XCTAssertFalse(isPathSafeToAccess(link.path))
    }

    func testNonexistentPathIsRejected() {
        XCTAssertFalse(isPathSafeToAccess("/nonexistent/path/\(UUID().uuidString)"))
    }

    func testDirectoryIsRejected() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertFalse(isPathSafeToAccess(tmp.path))
    }
}
