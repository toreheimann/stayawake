import AppKit
import IOKit.pwr_mgt
import ServiceManagement
import UserNotifications

let PMSET = "/usr/bin/pmset"
let CONFIG_PATH = NSString("~/.stayawake.json").expandingTildeInPath
let MAX_CONFIG_SIZE: UInt64 = 1_048_576

var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
}

// MARK: - Mode

enum Mode: String, Codable {
    case on, off

    /// The removed `auto` mode migrates to `.on`; any other unrecognized value is not something this app wrote,
    /// so it falls back to `.off` rather than silently forcing the Mac awake.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "auto": self = .on
        default: self = Mode(rawValue: raw) ?? .off
        }
    }
}

// MARK: - Config

struct StayAwakeConfig: Codable {
    var mode: Mode = .on
    var preventScreenLock = true

    static let `default` = StayAwakeConfig()

    /// Applied when a config file is present but unusable: neither sleep prevention nor screen-lock prevention
    /// may be turned on off the back of a file we could not read.
    static let safeFallback = StayAwakeConfig(mode: .off, preventScreenLock: false)
}

extension StayAwakeConfig {
    /// Each key decodes independently so config files written by older versions keep loading and one malformed
    /// value falls back to its own default instead of discarding every other key in the file.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedMode = try? container.decodeIfPresent(Mode.self, forKey: .mode)
        let decodedPreventScreenLock = try? container.decodeIfPresent(Bool.self, forKey: .preventScreenLock)
        mode = decodedMode.flatMap { $0 } ?? Self.default.mode
        preventScreenLock = decodedPreventScreenLock.flatMap { $0 } ?? Self.default.preventScreenLock
    }
}

func isPathSafeToAccess(_ path: String) -> Bool {
    var statBuf = stat()
    guard lstat(path, &statBuf) == 0 else { return false }
    return (statBuf.st_mode & S_IFMT) == S_IFREG
}

/// Loads the config, distinguishing "no config file yet" from "config file present but unusable".
///
/// - Returns: the config to run with, and a reason when the file was present but rejected. A rejected file
///   yields ``StayAwakeConfig/safeFallback`` — a config we cannot read must never mean "force the Mac awake".
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
        return (try JSONDecoder().decode(StayAwakeConfig.self, from: data), nil)
    } catch {
        return (.safeFallback, "\(path) is not valid StayAwake JSON: \(error.localizedDescription)")
    }
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
    private var notificationsAllowed = false

    /// Serial, so `cleanup`'s disable is ordered after any pmset call already in flight instead of racing it.
    private let sleepQueue = DispatchQueue(label: "com.signifly.stayawake.sleep")
    private let cleanupQueue = DispatchQueue(label: "com.signifly.stayawake.cleanup")
    private var _cleanedUp = false

    private var cleanedUp: Bool {
        get { cleanupQueue.sync { _cleanedUp } }
        set { cleanupQueue.sync { _cleanedUp = newValue } }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { [weak self] granted, _ in
            DispatchQueue.main.async { self?.notificationsAllowed = granted }
        }

        loadIcons()
        migrateConfigIfNeeded()
        let load = loadConfig()
        config = load.config

        if let saved = UserDefaults.standard.object(forKey: "originalSleep") as? Int {
            setSleepPrevention(enabled: false, restoreSleep: clampSleepValue(saved))
            UserDefaults.standard.removeObject(forKey: "originalSleep")
        }

        originalSleep = getSleepValue() ?? 1
        UserDefaults.standard.set(originalSleep, forKey: "originalSleep")

        setupStatusBar()
        setupMenu()

        if let reason = load.rejectionReason {
            showFailureAlert(
                "StayAwake could not read its settings",
                "\(reason)\n\nStarting with Keep Awake off. Changing a setting from the menu rewrites the file."
            )
        }

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
        keepAwakeItem.state = config.mode == .on ? .on : .off
        preventLockItem.state = config.preventScreenLock ? .on : .off
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func onToggleKeepAwake() {
        config.mode = config.mode == .on ? .off : .on
        saveConfig(config)
        updateMenuState()
        requestAwake(config.mode == .on)
    }

    @objc private func onTogglePreventScreenLock() {
        config.preventScreenLock.toggle()
        saveConfig(config)
        updateMenuState()
        updateDisplayAssertion()
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
            // Approval pending is not a failure — System Settings takes over below. Anything else the user must see,
            // because stderr goes nowhere for an LSUIElement app and the menu would otherwise look unchanged.
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

    /// Derived from `awake`, never `wantsAwake`: the screen must not stay unlocked on the strength of a sleep
    /// change that pmset rejected.
    private func updateDisplayAssertion() {
        displayAssertion.setActive(awake && config.preventScreenLock)
    }

    private func requestAwake(_ wanted: Bool) {
        wantsAwake = wanted
        // One pmset change at a time; on success the completion handler catches up to the latest wantsAwake.
        // A failed change is reported and rolled back to the observed state, not retried.
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

    /// pmset refused the change, so sleep behaviour is still whatever `awake` says. Bring intent, the persisted
    /// config, the assertion and the menu back to that, or every one of them claims a state the Mac is not in.
    private func rollBackFailedSleepChange() {
        wantsAwake = awake
        config.mode = awake ? .on : .off
        saveConfig(config)
        updateDisplayAssertion()
        updateMenuState()
        reportSleepControlFailure()
    }

    /// Notifications can be denied without telling the app, so an undelivered notification falls back to an alert.
    private func reportSleepControlFailure() {
        let title = "StayAwake could not change sleep settings"
        let body = "Sleep control failed. Check that StayAwake still has permission to run pmset."

        guard notificationsAllowed else {
            showFailureAlert(title, body)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "StayAwake"
        content.subtitle = "Sleep control failed"
        content.body = body
        let request = UNNotificationRequest(identifier: "sleep-failed", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard error != nil else { return }
            DispatchQueue.main.async { self?.showFailureAlert(title, body) }
        }
    }

    // MARK: Alerts

    /// The only failure channel this app has: it is an LSUIElement, so stderr reaches nobody.
    private func showFailureAlert(_ messageText: String, _ informativeText: String) {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alert.runModal()
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

    // MARK: Cleanup

    private func cleanup() {
        let shouldRun = cleanupQueue.sync { () -> Bool in
            if _cleanedUp { return false }
            _cleanedUp = true
            return true
        }
        guard shouldRun else { return }
        displayAssertion.setActive(false)
        // Through sleepQueue so an enable already running finishes first — otherwise the two pmset pairs interleave
        // and the enable can land last, leaving sleep disabled with the recovery key already removed.
        let restore = originalSleep
        let ok = sleepQueue.sync { setSleepPrevention(enabled: false, restoreSleep: restore) }
        if ok {
            UserDefaults.standard.removeObject(forKey: "originalSleep")
        }
    }

    @objc private func quitApp() {
        cleanup()
        NSApp.terminate(nil)
    }
}
