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

    func testWrongTypeFails() {
        XCTAssertThrowsError(try decode(#"{"preventScreenLock": "yes"}"#))
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

    func testInvalidModeFallsBackToOn() throws {
        let data = Data("\"banana\"".utf8)
        let mode = try JSONDecoder().decode(Mode.self, from: data)
        XCTAssertEqual(mode, .on)
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
