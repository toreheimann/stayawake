import AppKit
import IOKit.pwr_mgt
import ServiceManagement
import UserNotifications

let PMSET = "/usr/bin/pmset"
let CONFIG_PATH = NSString("~/.stayawake.json").expandingTildeInPath
let MAX_CONFIG_SIZE: UInt64 = 1_048_576
let CLEANUP_FAILURE_REMEDY = "The Mac is still set not to sleep. Run `sudo pmset -a disablesleep 0` in Terminal, or launch StayAwake again to restore it."
/// How long an exiting process waits for a cleanup-failure report to be taken before falling back to a modal.
/// The callers exit on their next statement, so the wait has to be bounded.
let CLEANUP_REPORT_TIMEOUT: DispatchTimeInterval = .seconds(2)

var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
}

// MARK: - Mode

enum Mode: String, Codable {
    case on, off

    /// The removed `auto` mode migrates to `.on`; any other unrecognized value is not something this app wrote and
    /// is rejected rather than resolved to a case, so ``StayAwakeConfig`` can name it in
    /// ``StayAwakeConfig/malformedKeys`` instead of silently substituting a mode the user never asked for.
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
    /// Keys that were present but unreadable, so their value came from ``safeFallback`` rather than the file.
    /// Never encoded — it describes one decode, not the user's settings.
    var malformedKeys: [String] = []

    enum CodingKeys: String, CodingKey {
        case mode, preventScreenLock
    }

    static let `default` = StayAwakeConfig()

    /// Applied when a config file is present but unusable: neither sleep prevention nor screen-lock prevention
    /// may be turned on off the back of a file we could not read.
    static let safeFallback = StayAwakeConfig(mode: .off, preventScreenLock: false)
}

extension StayAwakeConfig {
    /// Each key decodes independently so config files written by older versions keep loading and one unreadable
    /// value does not discard every other key in the file.
    ///
    /// Absence and unreadability are not the same thing. A key the file never mentions takes ``default``; a key that
    /// is there but cannot be read takes ``safeFallback`` and is named in ``malformedKeys``, because a value the app
    /// could not read must never be the reason it forces the Mac awake.
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
        let config = try JSONDecoder().decode(StayAwakeConfig.self, from: data)
        guard config.malformedKeys.isEmpty else {
            return (config, "\(path) has unreadable values for: \(config.malformedKeys.joined(separator: ", "))")
        }
        return (config, nil)
    } catch {
        return (.safeFallback, "\(path) is not valid StayAwake JSON: \(error.localizedDescription)")
    }
}

/// - Returns: whether the settings reached disk. A `false` return means the change is live but will not survive a
///   restart, which only an alert can tell the user — this app is an LSUIElement, so stderr reaches nobody.
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

// MARK: - Exit Reporting

/// Blocks until asynchronous work reports that it was accepted, so a caller about to exit does not die before the
/// work it asked for has been taken.
///
/// Only acceptance is signalled: a submission that fails times out into the caller's fallback rather than needing a
/// second channel to carry an error back across the wait.
///
/// - Parameter submit: receives a callback to invoke once, and only if the work was accepted.
/// - Returns: whether acceptance arrived inside `timeout`.
func waitForAcceptance(within timeout: DispatchTimeInterval, _ submit: (@escaping () -> Void) -> Void) -> Bool {
    let accepted = DispatchSemaphore(value: 0)
    submit { accepted.signal() }
    return accepted.wait(timeout: .now() + timeout) == .success
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
            // `saveConfig` refuses the same paths `isPathSafeToAccess` rejects, so telling that user to change a
            // setting from the menu would promise a write that provably will not happen.
            let remedy = isPathSafeToAccess(CONFIG_PATH)
                ? "Changing a setting from the menu rewrites the file."
                : "StayAwake will not write through a symlink or directory — move or delete \(CONFIG_PATH) to use the menu's settings."
            let state = config.mode == .on ? "Keep Awake stays on." : "Starting with Keep Awake off."
            showFailureAlert("StayAwake could not read its settings", "\(reason)\n\n\(state) \(remedy)")
        }

        if !checkSudoers() {
            requestPermissions()
        }

        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                if self?.cleanup() == false { self?.reportCleanupFailure() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }

        requestAwake(config.mode == .on)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        if !cleanup() { reportCleanupFailure() }
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
        // `wantsAwake`, not `config.mode`: the config is the user's persisted intent, while the menu has to be able
        // to show that a change pmset refused did not take. `rollBackFailedSleepChange` returns this to reality.
        keepAwakeItem.state = wantsAwake ? .on : .off
        preventLockItem.state = config.preventScreenLock ? .on : .off
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func onToggleKeepAwake() {
        // Toggles against the displayed state, not `config.mode`: after a failed change the two disagree, and a
        // click must then retry what the menu shows as off rather than flip the stored preference to match it.
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
        updateMenuState()
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

    /// pmset refused the change, so sleep behaviour is still whatever `awake` says. Bring the runtime state — intent,
    /// the assertion, the menu — back to that. `config` is deliberately untouched: it records what the user asked
    /// for, and a transient permission failure must not erase that from disk.
    private func rollBackFailedSleepChange() {
        wantsAwake = awake
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

    /// - Returns: whether the Mac was handed back its sleep settings. A `false` return leaves `originalSleep` in
    ///   place so the next launch retries, but the user who just quit has no reason to launch again — every caller
    ///   must report it. A repeat call returns `true`: the first one owns reporting.
    private func cleanup() -> Bool {
        let shouldRun = cleanupQueue.sync { () -> Bool in
            if _cleanedUp { return false }
            _cleanedUp = true
            return true
        }
        guard shouldRun else { return true }
        displayAssertion.setActive(false)
        // Through sleepQueue so an enable already running finishes first — otherwise the two pmset pairs interleave
        // and the enable can land last, leaving sleep disabled with the recovery key already removed.
        let restore = originalSleep
        let ok = sleepQueue.sync { setSleepPrevention(enabled: false, restoreSleep: restore) }
        if ok {
            UserDefaults.standard.removeObject(forKey: "originalSleep")
        } else {
            fputs("Warning: could not restore sleep settings on exit\n", stderr)
        }
        return ok
    }

    /// Exit paths the user did not drive get a notification: there is no window left to put a modal on, and the
    /// alternative is the Mac never sleeping again with nothing said.
    ///
    /// Blocks until the request is taken, because both callers exit on their next statement and an untaken request
    /// dies with the process. A notification that cannot be sent, or is not taken in time, falls back to the modal —
    /// the report is never dropped just because the preferred channel was unavailable.
    private func reportCleanupFailure() {
        let title = "StayAwake could not restore sleep settings"

        guard notificationsAllowed else {
            showFailureAlert(title, CLEANUP_FAILURE_REMEDY)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "StayAwake"
        content.subtitle = "Sleep settings not restored"
        content.body = CLEANUP_FAILURE_REMEDY
        let request = UNNotificationRequest(identifier: "cleanup-failed", content: content, trigger: nil)

        let reported = waitForAcceptance(within: CLEANUP_REPORT_TIMEOUT) { accept in
            UNUserNotificationCenter.current().add(request) { error in
                guard error == nil else { return }
                accept()
            }
        }
        if !reported {
            showFailureAlert(title, CLEANUP_FAILURE_REMEDY)
        }
    }

    @objc private func quitApp() {
        if !cleanup() {
            showFailureAlert("StayAwake could not restore sleep settings", CLEANUP_FAILURE_REMEDY)
        }
        NSApp.terminate(nil)
    }
}
