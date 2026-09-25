import AppKit
import IOKit.pwr_mgt
import ServiceManagement

let PMSET = "/usr/bin/pmset"
let CONFIG_PATH = NSString("~/.stayawake.json").expandingTildeInPath
let MAX_CONFIG_SIZE: UInt64 = 1_048_576
let CLEANUP_FAILURE_REMEDY = "The Mac is still set not to sleep. Run `sudo pmset -a disablesleep 0` in Terminal, or launch StayAwake again to restore it."
let RELAUNCH_RESTORE_FAILURE_REMEDY = "StayAwake couldn't confirm your sleep settings were restored after its last run. Run `sudo pmset -a disablesleep 0` in Terminal to make sure the Mac can sleep."

var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
}

// MARK: - Mode

enum Mode: String, Codable {
    case on, off

    /// The removed `auto` mode migrates to `.on`. Other unknown values throw, so the config decoder falls back safely.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if raw == "auto" {
            self = .on
            return
        }
        guard let mode = Mode(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unrecognized mode \"\(raw)\"")
        }
        self = mode
    }
}

// MARK: - Config

struct StayAwakeConfig: Codable {
    var mode: Mode = .on
    var preventScreenLock = true
    /// Keys present in the file but unreadable. Set by decoding, never encoded.
    var malformedKeys: [String] = []

    enum CodingKeys: String, CodingKey {
        case mode, preventScreenLock
    }

    static let `default` = StayAwakeConfig()

    /// For values that exist but can't be read: an unreadable config must never turn anything on.
    static let safeFallback = StayAwakeConfig(mode: .off, preventScreenLock: false)
}

extension StayAwakeConfig {
    /// Decodes each key on its own: a missing key takes ``default``, an unreadable one takes ``safeFallback`` and is
    /// listed in ``malformedKeys``.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var malformed: [String] = []

        if !container.contains(.mode) {
            mode = Self.default.mode
        } else if let decoded = try? container.decode(Mode.self, forKey: .mode) {
            mode = decoded
        } else {
            mode = Self.safeFallback.mode
            malformed.append(CodingKeys.mode.stringValue)
        }

        if !container.contains(.preventScreenLock) {
            preventScreenLock = Self.default.preventScreenLock
        } else if let decoded = try? container.decode(Bool.self, forKey: .preventScreenLock) {
            preventScreenLock = decoded
        } else {
            preventScreenLock = Self.safeFallback.preventScreenLock
            malformed.append(CodingKeys.preventScreenLock.stringValue)
        }

        malformedKeys = malformed
    }
}

func isPathSafeToAccess(_ path: String) -> Bool {
    var statBuf = stat()
    guard lstat(path, &statBuf) == 0 else { return false }
    return (statBuf.st_mode & S_IFMT) == S_IFREG
}

/// - Returns: the config, plus a reason when the file exists but was rejected or partly unreadable.
func loadConfig(path: String = CONFIG_PATH) -> (config: StayAwakeConfig, rejectionReason: String?) {
    var statBuf = stat()
    guard lstat(path, &statBuf) == 0 else { return (.default, nil) }

    guard isPathSafeToAccess(path) else {
        return (.safeFallback, "\(path) is not a regular file")
    }
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let size = attrs[.size] as? UInt64, size <= MAX_CONFIG_SIZE else {
        return (.safeFallback, "\(path) is unreadable or larger than \(MAX_CONFIG_SIZE) bytes")
    }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        return (.safeFallback, "\(path) could not be read")
    }
    do {
        let config = try JSONDecoder().decode(StayAwakeConfig.self, from: data)
        guard config.malformedKeys.isEmpty else {
            return (config, "\(path) has unreadable values for: \(config.malformedKeys.joined(separator: ", "))")
        }
        return (config, nil)
    } catch {
        return (.safeFallback, "\(path) is not valid StayAwake JSON: \(error.localizedDescription)")
    }
}

/// - Returns: whether the settings reached disk.
func saveConfig(_ config: StayAwakeConfig, path: String = CONFIG_PATH) -> Bool {
    var statBuf = stat()
    if lstat(path, &statBuf) == 0 {
        guard (statBuf.st_mode & S_IFMT) == S_IFREG else { return false }
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(config) else { return false }
    do {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return true
    } catch {
        fputs("Warning: could not save config\n", stderr)
        return false
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

/// Retries a sleep restore that a previous run left unfinished.
///
/// - Returns: the value still owed, or `nil` if nothing was owed or the retry worked. While it's non-nil, the Mac's
///   current sleep value is this app's own and must not be recorded as the original.
func retryUnfinishedSleepRestore(saved: Int?, restore: (Int) -> Bool) -> Int? {
    guard let saved else { return nil }
    let target = clampSleepValue(saved)
    return restore(target) ? nil : target
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

public class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var keepAwakeItem: NSMenuItem!
    private var preventLockItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!

    private var config: StayAwakeConfig!
    /// What the toggle asks for; `awake` lags it until pmset succeeds.
    private var wantsAwake = false
    private var awake = false
    private var sleepChangeInFlight = false
    private var originalSleep: Int = 1
    private let displayAssertion = DisplaySleepAssertion()

    private var iconActive: NSImage?
    private var iconInactive: NSImage?
    private var signalSources: [DispatchSourceSignal] = []

    /// Serial, so `cleanup`'s disable is ordered after any pmset call already in flight instead of racing it.
    private let sleepQueue = DispatchQueue(label: "com.signifly.stayawake.sleep")
    private let cleanupQueue = DispatchQueue(label: "com.signifly.stayawake.cleanup")
    private var _cleanedUp = false

    private var cleanedUp: Bool {
        get { cleanupQueue.sync { _cleanedUp } }
        set { cleanupQueue.sync { _cleanedUp = newValue } }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        loadIcons()
        migrateConfigIfNeeded()
        let load = loadConfig()
        config = load.config

        let savedSleep = UserDefaults.standard.object(forKey: "originalSleep") as? Int
        // Read once, before this run can touch pmset. A restore retry either returns the Mac to the saved value or
        // still owes it, so the saved value stays the original either way.
        originalSleep = savedSleep.map(clampSleepValue) ?? getSleepValue() ?? 1
        UserDefaults.standard.set(originalSleep, forKey: "originalSleep")

        // Icon now, so the launch is visible behind the permission prompt. The menu waits until the retry has run,
        // so nothing can toggle sleep before then.
        setupStatusBar()

        // Before the restore retry: it runs pmset through the sudoers rule this may install.
        if !checkSudoers() {
            requestPermissions()
        }

        let stillOwed = retryUnfinishedSleepRestore(saved: savedSleep) {
            setSleepPrevention(enabled: false, restoreSleep: $0)
        }

        setupMenu()

        if let reason = load.rejectionReason {
            let remedy = isPathSafeToAccess(CONFIG_PATH)
                ? "Changing a setting from the menu rewrites the file."
                : "StayAwake will not write through a symlink or directory — move or delete \(CONFIG_PATH) to use the menu's settings."
            let state = config.mode == .on ? "Keep Awake stays on." : "Starting with Keep Awake off."
            showFailureAlert("StayAwake could not read its settings", "\(reason)\n\n\(state) \(remedy)")
        }

        if stillOwed != nil {
            showFailureAlert("StayAwake could not restore sleep settings", RELAUNCH_RESTORE_FAILURE_REMEDY)
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

        requestAwake(config.mode == .on)
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
        menu.delegate = self

        keepAwakeItem = NSMenuItem(title: "Keep Awake", action: #selector(onToggleKeepAwake), keyEquivalent: "")
        keepAwakeItem.target = self
        menu.addItem(keepAwakeItem)

        preventLockItem = NSMenuItem(title: "Prevent Screen Lock", action: #selector(onTogglePreventScreenLock), keyEquivalent: "")
        preventLockItem.target = self
        preventLockItem.toolTip = "While awake, keep the display on so the Mac doesn't idle into the lock screen."
        menu.addItem(preventLockItem)
        menu.addItem(.separator())

        launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(onToggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())

        let versionItem = NSMenuItem(title: "StayAwake v\(appVersion)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        let quitItem = NSMenuItem(title: "Quit StayAwake", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateMenuState()
    }

    public func menuWillOpen(_ menu: NSMenu) {
        updateMenuState()
    }

    private func updateMenuState() {
        // `wantsAwake`, not `config.mode`, so a change pmset refused shows as not applied.
        keepAwakeItem.state = wantsAwake ? .on : .off
        preventLockItem.state = config.preventScreenLock ? .on : .off
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func onToggleKeepAwake() {
        // Toggles the displayed state, so after a failed change a click retries it.
        let wanted = !wantsAwake
        config.mode = wanted ? .on : .off
        persistConfig()
        requestAwake(wanted)
    }

    @objc private func onTogglePreventScreenLock() {
        config.preventScreenLock.toggle()
        persistConfig()
        updateMenuState()
        updateDisplayAssertion()
    }

    private func persistConfig() {
        guard !saveConfig(config) else { return }
        showFailureAlert(
            "StayAwake could not save its settings",
            "\(CONFIG_PATH) could not be written. The change applies now but will not survive a restart."
        )
    }

    @objc private func onToggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        let wasEnabled = service.status == .enabled
        do {
            if wasEnabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            // Pending approval isn't a failure; System Settings takes over below.
            if service.status != .requiresApproval {
                showFailureAlert(
                    wasEnabled ? "Could not turn off Launch at Login" : "Could not turn on Launch at Login",
                    error.localizedDescription
                )
            }
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        updateMenuState()
    }

    // MARK: Sleep Control

    /// Follows `awake`, not `wantsAwake`, so a sleep change pmset rejected never keeps the screen unlocked.
    private func updateDisplayAssertion() {
        displayAssertion.setActive(awake && config.preventScreenLock)
    }

    private func requestAwake(_ wanted: Bool) {
        wantsAwake = wanted
        updateMenuState()
        // One pmset change at a time; on success the handler catches up to the latest `wantsAwake`.
        // A failure rolls back instead of retrying.
        guard wanted != awake, !sleepChangeInFlight else { return }
        sleepChangeInFlight = true

        sleepQueue.async { [weak self] in
            guard let self, !self.cleanedUp else { return }
            let ok = setSleepPrevention(enabled: wanted, restoreSleep: self.originalSleep)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.cleanedUp else { return }
                self.sleepChangeInFlight = false
                guard ok else {
                    self.rollBackFailedSleepChange()
                    return
                }
                self.awake = wanted
                self.updateDisplayAssertion()
                self.statusItem.button?.image = wanted ? self.iconActive : self.iconInactive
                self.statusItem.button?.setAccessibilityTitle(wanted ? "StayAwake — preventing sleep" : "StayAwake — idle")
                if self.wantsAwake != wanted {
                    self.requestAwake(self.wantsAwake)
                }
            }
        }
    }

    /// pmset refused the change: return intent, assertion and menu to the applied state. `config` keeps the user's
    /// choice, so a transient permission failure doesn't overwrite it on disk.
    private func rollBackFailedSleepChange() {
        wantsAwake = awake
        updateDisplayAssertion()
        updateMenuState()
        showFailureAlert(
            "StayAwake could not change sleep settings",
            "Check that StayAwake still has permission to run pmset."
        )
    }

    // MARK: Alerts

    /// Activates first: an accessory app's modal otherwise opens behind the frontmost app's windows.
    private func showFailureAlert(_ messageText: String, _ informativeText: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: Permissions

    private func requestPermissions() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "StayAwake needs permission"
        alert.informativeText = "One-time admin access is needed to control sleep without a password prompt each time. Click Grant Access to proceed."
        alert.addButton(withTitle: "Grant Access")
        alert.addButton(withTitle: "Skip")
        alert.alertStyle = .informational

        if alert.runModal() == .alertFirstButtonReturn {
            if setupSudoers() {
                NSApp.activate(ignoringOtherApps: true)
                let ok = NSAlert()
                ok.messageText = "Permission granted!"
                ok.informativeText = "StayAwake is ready."
                ok.runModal()
            } else {
                showFailureAlert("Permission not granted", "StayAwake cannot control sleep without this permission.")
            }
        }
    }

    // MARK: Cleanup

    /// - Returns: whether the Mac got its sleep settings back. `false` leaves `originalSleep` in place so the next
    ///   launch retries. Repeat calls return `true`.
    @discardableResult
    private func cleanup() -> Bool {
        let shouldRun = cleanupQueue.sync { () -> Bool in
            if _cleanedUp { return false }
            _cleanedUp = true
            return true
        }
        guard shouldRun else { return true }
        displayAssertion.setActive(false)
        // Via `sleepQueue`, so an in-flight enable finishes before this disable instead of landing after it.
        let restore = originalSleep
        let ok = sleepQueue.sync { setSleepPrevention(enabled: false, restoreSleep: restore) }
        if ok {
            UserDefaults.standard.removeObject(forKey: "originalSleep")
        } else {
            fputs("Warning: could not restore sleep settings on exit\n", stderr)
        }
        return ok
    }

    @objc private func quitApp() {
        if !cleanup() {
            showFailureAlert("StayAwake could not restore sleep settings", CLEANUP_FAILURE_REMEDY)
        }
        NSApp.terminate(nil)
    }
}
