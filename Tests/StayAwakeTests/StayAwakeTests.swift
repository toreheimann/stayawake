import IOKit.pwr_mgt
import XCTest
@testable import StayAwakeLib

// MARK: - Process Name Matching

final class ProcessNameMatchesTests: XCTestCase {
    func testExactMatch() {
        XCTAssertTrue(processNameMatches("node", key: "node"))
    }

    func testPrefixWithDigit() {
        XCTAssertTrue(processNameMatches("python3.11", key: "python"))
    }

    func testPrefixWithHyphen() {
        XCTAssertTrue(processNameMatches("docker-compose", key: "docker"))
    }

    func testPrefixWithDot() {
        XCTAssertTrue(processNameMatches("node.js", key: "node"))
    }

    func testPrefixWithUnderscore() {
        XCTAssertTrue(processNameMatches("python3_test", key: "python3"))
    }

    func testRejectsLetterContinuation() {
        XCTAssertFalse(processNameMatches("google_crashpad_handler", key: "go"))
    }

    func testRejectsSubstringInMiddle() {
        XCTAssertFalse(processNameMatches("mongod", key: "go"))
    }

    func testRejectsNoPrefix() {
        XCTAssertFalse(processNameMatches("parentnode", key: "node"))
    }

    func testJavaDoesNotMatchJavascript() {
        XCTAssertFalse(processNameMatches("javascript", key: "java"))
    }
}

// MARK: - Find Matches

final class FindMatchesTests: XCTestCase {
    func testBasicMatch() {
        let running: Set<String> = ["node", "vim", "zsh"]
        let matches = findMatches(watched: ["node", "python"], running: running)
        XCTAssertEqual(matches, ["node"])
    }

    func testCaseInsensitive() {
        let running: Set<String> = ["node", "python3"]
        let matches = findMatches(watched: ["Node", "Python3"], running: running)
        XCTAssertEqual(matches, ["Node", "Python3"])
    }

    func testDeduplication() {
        let running: Set<String> = ["node"]
        let matches = findMatches(watched: ["node", "Node", "NODE"], running: running)
        XCTAssertEqual(matches, ["node"])
    }

    func testEmptyWatched() {
        XCTAssertEqual(findMatches(watched: [], running: ["node"]), [])
    }

    func testEmptyRunning() {
        XCTAssertEqual(findMatches(watched: ["node"], running: []), [])
    }

    func testPartialMatch() {
        let running: Set<String> = ["python3.11"]
        let matches = findMatches(watched: ["python"], running: running)
        XCTAssertEqual(matches, ["python"])
    }

    func testPreservesWatchedOrder() {
        let running: Set<String> = ["redis", "node", "docker"]
        let matches = findMatches(watched: ["docker", "node", "redis"], running: running)
        XCTAssertEqual(matches, ["docker", "node", "redis"])
    }

    func testNoFalsePositives() {
        let running: Set<String> = ["vim", "zsh", "finder"]
        let matches = findMatches(watched: ["node", "python", "docker"], running: running)
        XCTAssertTrue(matches.isEmpty)
    }

    func testNoSubstringFalsePositive() {
        let running: Set<String> = ["google_crashpad_handler", "mongod"]
        let matches = findMatches(watched: ["go"], running: running)
        XCTAssertTrue(matches.isEmpty)
    }

    func testPrefixMatchWithSeparator() {
        let running: Set<String> = ["docker-compose"]
        let matches = findMatches(watched: ["docker"], running: running)
        XCTAssertEqual(matches, ["docker"])
    }
}

// MARK: - Normalize Process Name

final class NormalizeProcessNameTests: XCTestCase {
    func testExtractsBasename() {
        XCTAssertEqual(normalizeProcessName("/usr/local/bin/python3.11"), "python3.11")
    }

    func testLowercases() {
        XCTAssertEqual(normalizeProcessName("/usr/local/bin/Docker"), "docker")
    }

    func testBareProcessName() {
        XCTAssertEqual(normalizeProcessName("node"), "node")
    }

    func testKeepsProcessTitleWithSpaces() {
        XCTAssertEqual(normalizeProcessName("next-server (v16.2.6)"), "next-server (v16.2.6)")
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(normalizeProcessName("  node "), "node")
    }
}

// MARK: - Parse argv[0]

final class ParseArgv0Tests: XCTestCase {
    private func procArgs(argc: Int32, execPath: String, padding: Int = 5, strings: [String]) -> [UInt8] {
        var bytes = withUnsafeBytes(of: argc) { Array($0) }
        bytes += Array(execPath.utf8) + [0]
        bytes += [UInt8](repeating: 0, count: padding)
        for s in strings { bytes += Array(s.utf8) + [0] }
        return bytes
    }

    private func parse(_ bytes: [UInt8]) -> String? {
        bytes.withUnsafeBytes { parseArgv0(procArgs: $0) }
    }

    func testTypicalArgs() {
        let bytes = procArgs(argc: 2, execPath: "/usr/local/bin/node", strings: ["node", "server.js", "PATH=/usr/bin"])
        XCTAssertEqual(parse(bytes), "node")
    }

    func testProcessTitleDiffersFromExecPath() {
        let bytes = procArgs(argc: 1, execPath: "/opt/homebrew/bin/node", strings: ["next-server (v16.2.6)"])
        XCTAssertEqual(parse(bytes), "next-server (v16.2.6)")
    }

    func testNoPadding() {
        let bytes = procArgs(argc: 1, execPath: "/bin/sleep", padding: 0, strings: ["sleep"])
        XCTAssertEqual(parse(bytes), "sleep")
    }

    func testZeroArgcRejected() {
        let bytes = procArgs(argc: 0, execPath: "/bin/sleep", strings: ["HOME=/Users/someone"])
        XCTAssertNil(parse(bytes))
    }

    func testUnterminatedArgv0Rejected() {
        let bytes = procArgs(argc: 1, execPath: "/bin/sleep", strings: ["sleep"]).dropLast()
        XCTAssertNil(parse(Array(bytes)))
    }

    func testMissingArgv0Rejected() {
        XCTAssertNil(parse(procArgs(argc: 1, execPath: "/bin/sleep", strings: [])))
    }

    func testTooShortRejected() {
        XCTAssertNil(parse([]))
        XCTAssertNil(parse([1, 0, 0]))
    }
}

// MARK: - Running Processes

final class RunningProcessesTests: XCTestCase {
    func testFindsChildByArgv0() throws {
        let marker = "stayawake-probe-\(UUID().uuidString.prefix(8).lowercased())"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", "exec -a \(marker) /bin/sleep 10"]
        try task.run()
        defer { task.terminate() }

        let deadline = Date().addingTimeInterval(5)
        var names = Set<String>()
        while Date() < deadline {
            names = try XCTUnwrap(getRunningProcesses())
            if names.contains(marker) { break }
            usleep(50_000)
        }
        XCTAssertTrue(names.contains(marker))
    }

    func testFallsBackToKernelNameForUnreadableArgs() throws {
        let names = try XCTUnwrap(getRunningProcesses())
        XCTAssertTrue(names.contains("launchd"))
    }
}

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

// MARK: - Config Validation

final class ValidateConfigTests: XCTestCase {
    func testValidConfigUnchanged() {
        let config = StayAwakeConfig(interval: 5, mode: .on, processes: ["node"])
        let result = validateConfig(config)
        XCTAssertEqual(result.interval, 5)
        XCTAssertEqual(result.mode, .on)
        XCTAssertEqual(result.processes, ["node"])
    }

    func testZeroIntervalResetToDefault() {
        let config = StayAwakeConfig(interval: 0, mode: .auto, processes: ["node"])
        XCTAssertEqual(validateConfig(config).interval, 10)
    }

    func testNegativeIntervalResetToDefault() {
        let config = StayAwakeConfig(interval: -5, mode: .auto, processes: ["node"])
        XCTAssertEqual(validateConfig(config).interval, 10)
    }

    func testIntervalAboveMaxResetToDefault() {
        let config = StayAwakeConfig(interval: 999, mode: .auto, processes: ["node"])
        XCTAssertEqual(validateConfig(config).interval, 10)
    }

    func testIntervalAtMaxBoundary() {
        let config = StayAwakeConfig(interval: 300, mode: .auto, processes: ["node"])
        XCTAssertEqual(validateConfig(config).interval, 300)
    }

    func testIntervalJustAboveMax() {
        let config = StayAwakeConfig(interval: 301, mode: .auto, processes: ["node"])
        XCTAssertEqual(validateConfig(config).interval, 10)
    }

    func testEmptyProcessesFilteredOut() {
        let config = StayAwakeConfig(interval: 10, mode: .auto, processes: ["node", "", "python"])
        let result = validateConfig(config)
        XCTAssertEqual(result.processes, ["node", "python"])
    }

    func testAllEmptyProcessesFallsBackToDefault() {
        let config = StayAwakeConfig(interval: 10, mode: .auto, processes: ["", ""])
        let result = validateConfig(config)
        XCTAssertEqual(result.processes, DEFAULT_PROCESSES)
    }

    func testEmptyProcessListFallsBackToDefault() {
        let config = StayAwakeConfig(interval: 10, mode: .auto, processes: [])
        let result = validateConfig(config)
        XCTAssertEqual(result.processes, DEFAULT_PROCESSES)
    }
}

// MARK: - Config Serialization

final class ConfigTests: XCTestCase {
    func testDefaultValues() {
        let config = StayAwakeConfig.default
        XCTAssertEqual(config.interval, 10)
        XCTAssertEqual(config.mode, .auto)
        XCTAssertFalse(config.processes.isEmpty)
    }

    func testDefaultProcessesContainCommonTools() {
        XCTAssertTrue(DEFAULT_PROCESSES.contains("node"))
        XCTAssertTrue(DEFAULT_PROCESSES.contains("docker"))
        XCTAssertTrue(DEFAULT_PROCESSES.contains("python3"))
        XCTAssertTrue(DEFAULT_PROCESSES.contains("claude"))
    }

    func testRoundTrip() throws {
        let config = StayAwakeConfig(interval: 5, mode: .on, processes: ["node", "python"], preventScreenLock: false)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(StayAwakeConfig.self, from: data)
        XCTAssertEqual(decoded.interval, 5)
        XCTAssertEqual(decoded.mode, .on)
        XCTAssertEqual(decoded.processes, ["node", "python"])
        XCTAssertFalse(decoded.preventScreenLock)
    }

    func testDefaultPreventsScreenLock() {
        XCTAssertTrue(StayAwakeConfig.default.preventScreenLock)
    }

    func testConfigWithoutPreventScreenLockStillDecodes() throws {
        let data = Data(#"{"interval": 20, "mode": "off", "processes": ["node"]}"#.utf8)
        let decoded = try JSONDecoder().decode(StayAwakeConfig.self, from: data)
        XCTAssertEqual(decoded.interval, 20)
        XCTAssertEqual(decoded.mode, .off)
        XCTAssertEqual(decoded.processes, ["node"])
        XCTAssertTrue(decoded.preventScreenLock)
    }

    func testMissingRequiredKeyStillFails() {
        let data = Data(#"{"mode": "off", "processes": ["node"]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(StayAwakeConfig.self, from: data))
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
    func testDecodesAuto() throws {
        let data = Data("\"auto\"".utf8)
        let mode = try JSONDecoder().decode(Mode.self, from: data)
        XCTAssertEqual(mode, .auto)
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

    func testInvalidModeFallsBackToAuto() throws {
        let data = Data("\"banana\"".utf8)
        let mode = try JSONDecoder().decode(Mode.self, from: data)
        XCTAssertEqual(mode, .auto)
    }

    func testModeRoundTrip() throws {
        for mode in [Mode.auto, .on, .off] {
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

// MARK: - Sanitize For Display

final class SanitizeForDisplayTests: XCTestCase {
    func testNormalStringUnchanged() {
        XCTAssertEqual(sanitizeForDisplay("node"), "node")
    }

    func testStripsControlCharacters() {
        XCTAssertEqual(sanitizeForDisplay("no\u{0000}de"), "node")
    }

    func testStripsNullByte() {
        XCTAssertEqual(sanitizeForDisplay("hel\u{0000}lo"), "hello")
    }

    func testStripsBidiOverrides() {
        XCTAssertEqual(sanitizeForDisplay("node\u{202E}evil"), "nodeevil")
    }

    func testStripsRLO() {
        XCTAssertEqual(sanitizeForDisplay("\u{202E}abc"), "abc")
    }

    func testStripsLRO() {
        XCTAssertEqual(sanitizeForDisplay("\u{202D}test"), "test")
    }

    func testStripsZeroWidthChars() {
        XCTAssertEqual(sanitizeForDisplay("a\u{200B}b\u{200C}c"), "abc")
    }

    func testStripsBidiIsolates() {
        XCTAssertEqual(sanitizeForDisplay("\u{2066}text\u{2069}"), "text")
    }

    func testTruncatesLongStrings() {
        let long = String(repeating: "a", count: 100)
        let result = sanitizeForDisplay(long)
        XCTAssertEqual(result.count, 51)
        XCTAssertTrue(result.hasSuffix("…"))
    }

    func testExactly50CharsNotTruncated() {
        let exact = String(repeating: "a", count: 50)
        XCTAssertEqual(sanitizeForDisplay(exact), exact)
    }

    func test51CharsTruncated() {
        let over = String(repeating: "b", count: 51)
        let result = sanitizeForDisplay(over)
        XCTAssertEqual(result, String(repeating: "b", count: 50) + "…")
    }

    func testEmptyStringUnchanged() {
        XCTAssertEqual(sanitizeForDisplay(""), "")
    }

    func testMixedUnsafeChars() {
        XCTAssertEqual(sanitizeForDisplay("\u{200E}no\u{202A}de\u{0007}"), "node")
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
