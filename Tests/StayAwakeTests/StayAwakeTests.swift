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

// MARK: - Parse Process List

final class ParseProcessListTests: XCTestCase {
    func testBasicParsing() {
        let output = "  PID COMM\n  123 /usr/local/bin/node\n  456 /usr/bin/vim"
        let procs = parseProcessList(output, excludingPid: 0)
        XCTAssertEqual(procs, ["node", "vim"])
    }

    func testExtractsBasename() {
        let output = "  PID COMM\n  100 /usr/local/bin/python3.11"
        let procs = parseProcessList(output, excludingPid: 0)
        XCTAssertTrue(procs.contains("python3.11"))
    }

    func testLowercases() {
        let output = "  PID COMM\n  100 /usr/local/bin/Docker"
        let procs = parseProcessList(output, excludingPid: 0)
        XCTAssertTrue(procs.contains("docker"))
    }

    func testSkipsHeaderLine() {
        let output = "  PID COMM\n  123 node"
        let procs = parseProcessList(output, excludingPid: 0)
        XCTAssertEqual(procs.count, 1)
        XCTAssertTrue(procs.contains("node"))
    }

    func testExcludesPid() {
        let output = "  100 node\n  200 vim"
        let procs = parseProcessList(output, excludingPid: 100)
        XCTAssertFalse(procs.contains("node"))
        XCTAssertTrue(procs.contains("vim"))
    }

    func testEmptyOutput() {
        let procs = parseProcessList("", excludingPid: 0)
        XCTAssertTrue(procs.isEmpty)
    }

    func testBareProcessName() {
        let output = "  100 node"
        let procs = parseProcessList(output, excludingPid: 0)
        XCTAssertTrue(procs.contains("node"))
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
        let config = StayAwakeConfig(interval: 5, mode: .on, processes: ["node", "python"])
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(StayAwakeConfig.self, from: data)
        XCTAssertEqual(decoded.interval, 5)
        XCTAssertEqual(decoded.mode, .on)
        XCTAssertEqual(decoded.processes, ["node", "python"])
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
