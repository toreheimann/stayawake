import AppKit
import IOKit.pwr_mgt
import ServiceManagement
import UserNotifications

let PMSET = "/usr/bin/pmset"
let CONFIG_PATH = NSString("~/.stayawake.json").expandingTildeInPath
let MAX_CONFIG_SIZE: UInt64 = 1_048_576
let MAX_INTERVAL = 300

let DEFAULT_PROCESSES = [
    "node", "npm", "pnpm", "yarn", "bun",
    "python", "python3",
    "docker", "docker-compose",
    "ruby", "rails",
    "go", "cargo",
    "java",
    "vite", "webpack", "next", "nuxt", "gatsby",
    "postgres", "mysql", "redis", "mongod",
    "claude",
]

var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
}

// MARK: - Mode

enum Mode: String, Codable {
    case auto, on, off

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Mode(rawValue: raw) ?? .auto
    }
}

// MARK: - Config

struct StayAwakeConfig: Codable {
    var interval: Int
    var mode: Mode
    var processes: [String]
    var preventScreenLock = true

    static let `default` = StayAwakeConfig(
        interval: 10,
        mode: .auto,
        processes: DEFAULT_PROCESSES
    )
}

extension StayAwakeConfig {
    /// Keys added after the first release decode leniently so existing config files keep loading.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        interval = try container.decode(Int.self, forKey: .interval)
        mode = try container.decode(Mode.self, forKey: .mode)
        processes = try container.decode([String].self, forKey: .processes)
        preventScreenLock = try container.decodeIfPresent(Bool.self, forKey: .preventScreenLock) ?? true
    }
}

func validateConfig(_ config: StayAwakeConfig) -> StayAwakeConfig {
    var config = config
    if config.interval < 1 || config.interval > MAX_INTERVAL {
        config.interval = StayAwakeConfig.default.interval
    }
    config.processes = config.processes.filter { !$0.isEmpty }
    if config.processes.isEmpty { config.processes = DEFAULT_PROCESSES }
    return config
}

func isPathSafeToAccess(_ path: String) -> Bool {
    var statBuf = stat()
    guard lstat(path, &statBuf) == 0 else { return false }
    return (statBuf.st_mode & S_IFMT) == S_IFREG
}

func loadConfig() -> StayAwakeConfig {
    guard isPathSafeToAccess(CONFIG_PATH),
          let attrs = try? FileManager.default.attributesOfItem(atPath: CONFIG_PATH),
          let size = attrs[.size] as? UInt64,
          size <= MAX_CONFIG_SIZE,
          let data = try? Data(contentsOf: URL(fileURLWithPath: CONFIG_PATH)),
          let config = try? JSONDecoder().decode(StayAwakeConfig.self, from: data) else {
        return .default
    }
    return validateConfig(config)
}

func saveConfig(_ config: StayAwakeConfig) {
    var statBuf = stat()
    if lstat(CONFIG_PATH, &statBuf) == 0 {
        guard (statBuf.st_mode & S_IFMT) == S_IFREG else { return }
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(config) else { return }
    do {
        try data.write(to: URL(fileURLWithPath: CONFIG_PATH), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: CONFIG_PATH)
    } catch {
        fputs("Warning: could not save config\n", stderr)
    }
}

func migrateConfigIfNeeded() {
    guard isPathSafeToAccess(CONFIG_PATH),
          let data = try? Data(contentsOf: URL(fileURLWithPath: CONFIG_PATH)),
          var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let savedSleep = json["_original_sleep"] as? Int else { return }

    UserDefaults.standard.set(clampSleepValue(savedSleep), forKey: "originalSleep")
    json.removeValue(forKey: "_original_sleep")
    guard let cleanData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return }
    try? cleanData.write(to: URL(fileURLWithPath: CONFIG_PATH), options: .atomic)
}

// MARK: - Process Monitor

func normalizeProcessName(_ raw: String) -> String {
    let name = raw.split(separator: "/").last.map(String.init) ?? raw
    return name.trimmingCharacters(in: .whitespaces).lowercased()
}

/// Extracts argv[0] from a `KERN_PROCARGS2` buffer: `Int32` argc, exec path, NUL padding, then argv strings.
func parseArgv0(procArgs buffer: UnsafeRawBufferPointer) -> String? {
    var i = MemoryLayout<Int32>.size
    guard buffer.count > i, buffer.loadUnaligned(as: Int32.self) > 0 else { return nil }
    while i < buffer.count, buffer[i] != 0 { i += 1 }
    while i < buffer.count, buffer[i] == 0 { i += 1 }
    let start = i
    while i < buffer.count, buffer[i] != 0 { i += 1 }
    guard i > start, i < buffer.count else { return nil }
    return String(decoding: buffer[start..<i], as: UTF8.self)
}

private func readArgv0(pid: pid_t, buffer: UnsafeMutableRawBufferPointer) -> String? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = buffer.count
    guard sysctl(&mib, 3, buffer.baseAddress, &size, nil, 0) == 0 else { return nil }
    return parseArgv0(procArgs: UnsafeRawBufferPointer(rebasing: buffer[..<size]))
}

private func kernelName(of proc: kinfo_proc) -> String {
    withUnsafeBytes(of: proc.kp_proc.p_comm) { bytes in
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}

private func listAllProcesses() -> [kinfo_proc]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    for _ in 0..<3 {
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return nil }
        size += size / 8
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        if sysctl(&mib, 4, &procs, &size, nil, 0) == 0 {
            return Array(procs.prefix(size / MemoryLayout<kinfo_proc>.stride))
        }
        guard errno == ENOMEM else { return nil }
    }
    return nil
}

/// Normalized names of all live processes except this one: argv[0] where readable (so process
/// titles like `next-server` match), otherwise the kernel's truncated `p_comm`.
/// Returns nil when the process table can't be read, so callers can keep their current state.
func getRunningProcesses() -> Set<String>? {
    guard let procs = listAllProcesses() else { return nil }

    var argMax: Int32 = 0
    var argMaxSize = MemoryLayout<Int32>.size
    var argMaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
    guard sysctl(&argMaxMib, 2, &argMax, &argMaxSize, nil, 0) == 0, argMax > 0 else { return nil }
    let args = UnsafeMutableRawBufferPointer.allocate(byteCount: Int(argMax), alignment: MemoryLayout<Int32>.alignment)
    defer { args.deallocate() }

    let ownPid = getpid()
    var names = Set<String>()
    for proc in procs where proc.kp_proc.p_pid != ownPid && Int32(proc.kp_proc.p_stat) != SZOMB {
        let raw = readArgv0(pid: proc.kp_proc.p_pid, buffer: args) ?? kernelName(of: proc)
        let name = normalizeProcessName(raw)
        if !name.isEmpty { names.insert(name) }
    }
    return names
}

func processNameMatches(_ processName: String, key: String) -> Bool {
    guard processName.hasPrefix(key) else { return false }
    if processName.count == key.count { return true }
    let nextChar = processName[processName.index(processName.startIndex, offsetBy: key.count)]
    return !nextChar.isLetter
}

func findMatches(watched: [String], running: Set<String>) -> [String] {
    var seen = Set<String>()
    var result = [String]()
    for p in watched {
        let key = p.lowercased()
        guard !seen.contains(key) else { continue }
        if running.contains(where: { processNameMatches($0, key: key) }) {
            seen.insert(key)
            result.append(p)
        }
    }
    return result
}

let unsafeDisplayScalars: CharacterSet = {
    var set = CharacterSet.controlCharacters
    set.insert(charactersIn: "\u{200B}\u{200C}\u{200D}\u{200E}\u{200F}")
    set.insert(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}")
    set.insert(charactersIn: "\u{2066}\u{2067}\u{2068}\u{2069}")
    return set
}()

func sanitizeForDisplay(_ name: String) -> String {
    let cleaned = name.unicodeScalars.filter { !unsafeDisplayScalars.contains($0) }
    let result = String(String.UnicodeScalarView(cleaned))
    return result.count > 50 ? String(result.prefix(50)) + "…" : result
}

// MARK: - Display Sleep Assertion

/// Holds a `PreventUserIdleDisplaySleep` power assertion while active.
final class DisplaySleepAssertion {
    private var id = IOPMAssertionID(kIOPMNullAssertionID)

    var isActive: Bool { id != IOPMAssertionID(kIOPMNullAssertionID) }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        if !active {
            IOPMAssertionRelease(id)
            id = IOPMAssertionID(kIOPMNullAssertionID)
            return
        }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "StayAwake is preventing idle display sleep and screen lock" as CFString,
            &id
        )
        if result != kIOReturnSuccess {
            id = IOPMAssertionID(kIOPMNullAssertionID)
            fputs("Warning: could not create display sleep assertion (\(result))\n", stderr)
        }
    }

    deinit { setActive(false) }
}

// MARK: - Sleep Controller

func clampSleepValue(_ value: Int) -> Int {
    max(1, min(value, 180))
}

@discardableResult
func setSleepPrevention(enabled: Bool, restoreSleep: Int = 1) -> Bool {
    let val = enabled ? "1" : "0"
    let r1 = runProcess("/usr/bin/sudo", args: [PMSET, "-a", "disablesleep", val])
    if !r1 { return false }

    let sleepVal = enabled ? "0" : String(restoreSleep)
    let r2 = runProcess("/usr/bin/sudo", args: [PMSET, "-a", "sleep", sleepVal])
    if !r2 {
        let rollbackVal = enabled ? "0" : "1"
        _ = runProcess("/usr/bin/sudo", args: [PMSET, "-a", "disablesleep", rollbackVal])
        return false
    }
    return true
}

func parseSleepValue(from output: String) -> Int? {
    for line in output.split(separator: "\n") {
        let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
        if parts.count >= 2 && parts[0] == "sleep" {
            return Int(parts[1])
        }
    }
    return nil
}

func getSleepValue() -> Int? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: PMSET)
    task.arguments = ["-g"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice

    guard (try? task.run()) != nil else { return nil }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()

    guard let output = String(data: data, encoding: .utf8) else { return nil }
    return parseSleepValue(from: output)
}

func isValidUsername(_ username: String) -> Bool {
    !username.isEmpty && username.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) != nil
}

func buildSudoersRule(for username: String) -> String {
    let commands = [
        "/usr/bin/pmset -a disablesleep 0",
        "/usr/bin/pmset -a disablesleep 1",
        "/usr/bin/pmset -a sleep [0-9]",
        "/usr/bin/pmset -a sleep [0-9][0-9]",
        "/usr/bin/pmset -a sleep [0-9][0-9][0-9]",
        "/usr/bin/pmset -g",
    ].joined(separator: ", ")
    return "\(username) ALL=(root) NOPASSWD: \(commands)"
}

func setupSudoers() -> Bool {
    let username = NSUserName()
    guard isValidUsername(username) else { return false }

    let rule = buildSudoersRule(for: username)
    let escapedRule = rule.replacingOccurrences(of: "'", with: "'\\''")
    let script = "do shell script \"echo '\(escapedRule)' > /etc/sudoers.d/stayawake && chmod 440 /etc/sudoers.d/stayawake && /usr/sbin/visudo -c -f /etc/sudoers.d/stayawake || (rm -f /etc/sudoers.d/stayawake && exit 1)\" with administrator privileges"
    return runProcess("/usr/bin/osascript", args: ["-e", script])
}

func checkSudoers() -> Bool {
    return runProcess("/usr/bin/sudo", args: ["-n", PMSET, "-g"])
}

private func runProcess(_ path: String, args: [String]) -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = args
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return false }
    task.waitUntilExit()
    return task.terminationStatus == 0
}

// MARK: - App Delegate

public class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var activeItem: NSMenuItem!
    private var modeAutoItem: NSMenuItem!
    private var modeOnItem: NSMenuItem!
    private var modeOffItem: NSMenuItem!
    private var preventLockItem: NSMenuItem!

    private var config: StayAwakeConfig!
    /// What mode/processes ask for; `awake` lags it until pmset succeeds.
    private var wantsAwake = false
    private var awake = false
    private var sleepChangeInFlight = false
    private var originalSleep: Int = 1
    private var pollTimer: Timer?
    private var shownMatches: [String]?
    private let displayAssertion = DisplaySleepAssertion()

    private var iconActive: NSImage?
    private var iconInactive: NSImage?
    private var signalSources: [DispatchSourceSignal] = []

    private var settingsPanel: NSPanel?
    private var settingsIntervalField: NSTextField?
    private var settingsTextView: NSTextView?
    private var settingsLoginCheck: NSButton?

    private let cleanupQueue = DispatchQueue(label: "com.signifly.stayawake.cleanup")
    private var _cleanedUp = false

    private var cleanedUp: Bool {
        get { cleanupQueue.sync { _cleanedUp } }
        set { cleanupQueue.sync { _cleanedUp = newValue } }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }

        loadIcons()
        migrateConfigIfNeeded()
        config = loadConfig()

        if let saved = UserDefaults.standard.object(forKey: "originalSleep") as? Int {
            setSleepPrevention(enabled: false, restoreSleep: clampSleepValue(saved))
            UserDefaults.standard.removeObject(forKey: "originalSleep")
        }

        originalSleep = getSleepValue() ?? 1
        UserDefaults.standard.set(originalSleep, forKey: "originalSleep")

        setupStatusBar()
        setupMenu()

        if !checkSudoers() {
            requestPermissions()
        }

        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.cleanup()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }

        applyMode(startTimer: true)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        cleanup()
    }

    // MARK: Icons

    private func loadIcons() {
        let bundle = Bundle.main.resourcePath ?? FileManager.default.currentDirectoryPath
        let pointSize = NSSize(width: 20, height: 20)
        iconActive = NSImage(contentsOfFile: "\(bundle)/icon.png")
        iconActive?.size = pointSize
        iconActive?.isTemplate = true
        iconInactive = NSImage(contentsOfFile: "\(bundle)/icon_inactive.png")
        iconInactive?.size = pointSize
        iconInactive?.isTemplate = true

        if iconActive == nil {
            iconActive = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Active")
            iconActive?.isTemplate = true
        }
        if iconInactive == nil {
            iconInactive = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: "Inactive")
            iconInactive?.isTemplate = true
        }
    }

    // MARK: Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = iconInactive
        statusItem.button?.setAccessibilityTitle("StayAwake")
    }

    // MARK: Menu

    private func setupMenu() {
        let menu = NSMenu()

        activeItem = NSMenuItem(title: "No watched processes running", action: nil, keyEquivalent: "")
        activeItem.isEnabled = false
        menu.addItem(activeItem)

        let separatorAfterStatus = NSMenuItem.separator()
        separatorAfterStatus.tag = 999
        menu.addItem(separatorAfterStatus)

        let modeMenu = NSMenu()
        modeAutoItem = NSMenuItem(title: "Auto", action: #selector(onModeAuto), keyEquivalent: "")
        modeAutoItem.target = self
        modeOnItem = NSMenuItem(title: "Always On", action: #selector(onModeOn), keyEquivalent: "")
        modeOnItem.target = self
        modeOffItem = NSMenuItem(title: "Always Off", action: #selector(onModeOff), keyEquivalent: "")
        modeOffItem.target = self
        modeMenu.addItem(modeAutoItem)
        modeMenu.addItem(modeOnItem)
        modeMenu.addItem(modeOffItem)

        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        modeItem.image = NSImage(systemSymbolName: "switch.2", accessibilityDescription: "Mode")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        preventLockItem = NSMenuItem(title: "Prevent Screen Lock", action: #selector(onTogglePreventScreenLock), keyEquivalent: "")
        preventLockItem.target = self
        preventLockItem.image = NSImage(systemSymbolName: "lock.display", accessibilityDescription: "Prevent Screen Lock")
        preventLockItem.toolTip = "Keep the display awake while StayAwake is active, so the Mac doesn't idle into the lock screen."
        preventLockItem.state = config.preventScreenLock ? .on : .off
        menu.addItem(preventLockItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let versionItem = NSMenuItem(title: "StayAwake v\(appVersion)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        let quitItem = NSMenuItem(title: "Quit StayAwake", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateModeMenu()
    }

    // MARK: Mode

    private func updateModeMenu() {
        modeAutoItem.state = config.mode == .auto ? .on : .off
        modeOnItem.state = config.mode == .on ? .on : .off
        modeOffItem.state = config.mode == .off ? .on : .off
    }

    @objc private func onModeAuto() { changeMode(.auto) }
    @objc private func onModeOn() { changeMode(.on) }
    @objc private func onModeOff() { changeMode(.off) }

    private func changeMode(_ mode: Mode) {
        config.mode = mode
        saveConfig(config)
        updateModeMenu()
        applyMode(startTimer: true)
    }

    @objc private func onTogglePreventScreenLock() {
        config.preventScreenLock.toggle()
        saveConfig(config)
        preventLockItem.state = config.preventScreenLock ? .on : .off
        updateDisplayAssertion()
    }

    private func applyMode(startTimer: Bool) {
        pollTimer?.invalidate()
        pollTimer = nil
        removeMatchItems()

        switch config.mode {
        case .on:
            requestAwake(true)
            activeItem.title = "Always On"
            statusItem.button?.setAccessibilityTitle("StayAwake — always on")
        case .off:
            requestAwake(false)
            activeItem.title = "Always Off"
            statusItem.button?.setAccessibilityTitle("StayAwake — always off")
        case .auto:
            if startTimer {
                let interval = TimeInterval(config.interval)
                let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                    self?.poll()
                }
                timer.tolerance = interval / 10
                pollTimer = timer
                poll()
            }
        }
    }

    // MARK: Polling

    private func poll() {
        let processes = config.processes
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let running = getRunningProcesses() else { return }
            let matches = findMatches(watched: processes, running: running)

            DispatchQueue.main.async {
                guard let self, self.config.mode == .auto else { return }
                self.requestAwake(!matches.isEmpty)
                self.updateStatusDisplay(matches: matches)
            }
        }
    }

    private static let extraItemTag = 100

    private func removeMatchItems() {
        shownMatches = nil
        guard let menu = statusItem.menu else { return }
        while let item = menu.item(withTag: Self.extraItemTag) {
            menu.removeItem(item)
        }
    }

    private func updateStatusDisplay(matches: [String]) {
        guard matches != shownMatches, let menu = statusItem.menu else { return }
        removeMatchItems()
        shownMatches = matches

        if matches.isEmpty {
            activeItem.title = "No watched processes running"
            statusItem.button?.setAccessibilityTitle("StayAwake — idle")
            return
        }

        activeItem.title = "Active:"
        statusItem.button?.setAccessibilityTitle("StayAwake — preventing sleep")

        let insertIndex = menu.index(of: activeItem) + 1
        for (i, name) in matches.enumerated() {
            let item = NSMenuItem(title: sanitizeForDisplay(name), action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.tag = Self.extraItemTag
            menu.insertItem(item, at: insertIndex + i)
        }
    }

    // MARK: Sleep Control

    private func updateDisplayAssertion() {
        displayAssertion.setActive(wantsAwake && config.preventScreenLock)
    }

    private func requestAwake(_ wanted: Bool) {
        wantsAwake = wanted
        updateDisplayAssertion()
        // One pmset change at a time; the completion handler catches up to the latest wantsAwake.
        guard wanted != awake, !sleepChangeInFlight else { return }
        sleepChangeInFlight = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self, !self.cleanedUp else { return }
            let ok = setSleepPrevention(enabled: wanted, restoreSleep: self.originalSleep)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.cleanedUp else { return }
                self.sleepChangeInFlight = false
                if !ok {
                    let content = UNMutableNotificationContent()
                    content.title = "StayAwake"
                    content.subtitle = "Sleep control failed"
                    content.body = "Could not change sleep settings. Check permissions."
                    let request = UNNotificationRequest(identifier: "sleep-failed", content: content, trigger: nil)
                    UNUserNotificationCenter.current().add(request)
                    return
                }
                self.awake = wanted
                self.statusItem.button?.image = wanted ? self.iconActive : self.iconInactive
                self.statusItem.button?.setAccessibilityTitle(wanted ? "StayAwake — preventing sleep" : "StayAwake — idle")
                if self.wantsAwake != wanted {
                    self.requestAwake(self.wantsAwake)
                }
            }
        }
    }

    // MARK: Permissions

    private func requestPermissions() {
        let alert = NSAlert()
        alert.messageText = "StayAwake needs permission"
        alert.informativeText = "One-time admin access is needed to control sleep without a password prompt each time. Click Grant Access to proceed."
        alert.addButton(withTitle: "Grant Access")
        alert.addButton(withTitle: "Skip")
        alert.alertStyle = .informational

        if alert.runModal() == .alertFirstButtonReturn {
            if setupSudoers() {
                let ok = NSAlert()
                ok.messageText = "Permission granted!"
                ok.informativeText = "StayAwake is ready."
                ok.runModal()
            } else {
                let fail = NSAlert()
                fail.messageText = "Permission not granted"
                fail.informativeText = "StayAwake cannot control sleep without this permission."
                fail.alertStyle = .warning
                fail.runModal()
            }
        }
    }

    // MARK: Settings

    @objc private func openSettings() {
        if let panel = settingsPanel {
            panel.makeKeyAndOrderFront(nil)
            if #available(macOS 14, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "StayAwake Settings"
        panel.isFloatingPanel = true
        panel.level = .floating

        let contentView = NSView(frame: panel.contentRect(forFrameRect: panel.frame))

        let intervalLabel = NSTextField(labelWithString: "Check interval (seconds):")
        intervalLabel.frame = NSRect(x: 20, y: 255, width: 200, height: 20)
        contentView.addSubview(intervalLabel)

        let intervalField = NSTextField(frame: NSRect(x: 20, y: 230, width: 100, height: 24))
        intervalField.stringValue = String(config.interval)
        contentView.addSubview(intervalField)

        let processLabel = NSTextField(labelWithString: "Watched processes (comma-separated):")
        processLabel.frame = NSRect(x: 20, y: 200, width: 380, height: 20)
        contentView.addSubview(processLabel)

        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 90, width: 380, height: 105))
        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = true
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.string = config.processes.joined(separator: ", ")
        textView.autoresizingMask = [.width, .height]
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        contentView.addSubview(scrollView)

        let loginCheck = NSButton(checkboxWithTitle: "Launch at Login", target: nil, action: nil)
        loginCheck.frame = NSRect(x: 20, y: 55, width: 200, height: 20)
        loginCheck.state = SMAppService.mainApp.status == .enabled ? .on : .off
        contentView.addSubview(loginCheck)

        let saveButton = NSButton(title: "Save", target: nil, action: nil)
        saveButton.frame = NSRect(x: 310, y: 15, width: 90, height: 30)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        contentView.addSubview(saveButton)

        let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.frame = NSRect(x: 210, y: 15, width: 90, height: 30)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        contentView.addSubview(cancelButton)

        panel.contentView = contentView
        panel.center()

        saveButton.target = self
        saveButton.action = #selector(settingsSave(_:))
        cancelButton.target = self
        cancelButton.action = #selector(settingsCancel(_:))

        settingsPanel = panel
        settingsIntervalField = intervalField
        settingsTextView = textView
        settingsLoginCheck = loginCheck

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsPanelClosed(_:)),
            name: NSWindow.willCloseNotification,
            object: panel
        )

        panel.makeKeyAndOrderFront(nil)
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func settingsSave(_ sender: NSButton) {
        guard let intervalField = settingsIntervalField,
              let textView = settingsTextView,
              let loginCheck = settingsLoginCheck else { return }

        let interval = min(MAX_INTERVAL, max(1, Int(intervalField.stringValue) ?? config.interval))
        let processes = textView.string.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        config.interval = interval
        config.processes = processes
        saveConfig(config)

        let wantLogin = loginCheck.state == .on
        let currentlyEnabled = SMAppService.mainApp.status == .enabled
        if wantLogin && !currentlyEnabled {
            try? SMAppService.mainApp.register()
        } else if !wantLogin && currentlyEnabled {
            try? SMAppService.mainApp.unregister()
        }

        applyMode(startTimer: true)
        settingsPanel?.close()
    }

    @objc private func settingsCancel(_ sender: NSButton) {
        settingsPanel?.close()
    }

    @objc private func settingsPanelClosed(_ notification: Notification) {
        guard (notification.object as? NSPanel) === settingsPanel else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: settingsPanel)
        settingsPanel = nil
        settingsIntervalField = nil
        settingsTextView = nil
        settingsLoginCheck = nil
    }

    // MARK: Cleanup

    private func cleanup() {
        let shouldRun = cleanupQueue.sync { () -> Bool in
            if _cleanedUp { return false }
            _cleanedUp = true
            return true
        }
        guard shouldRun else { return }
        displayAssertion.setActive(false)
        let ok = setSleepPrevention(enabled: false, restoreSleep: originalSleep)
        if ok {
            UserDefaults.standard.removeObject(forKey: "originalSleep")
        }
    }

    @objc private func quitApp() {
        cleanup()
        NSApp.terminate(nil)
    }
}
