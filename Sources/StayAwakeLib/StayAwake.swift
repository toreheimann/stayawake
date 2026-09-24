import AppKit
import IOKit.pwr_mgt
import ServiceManagement
import UserNotifications

let PMSET = "/usr/bin/pmset"
let CONFIG_PATH = NSString("~/.stayawake.json").expandingTildeInPath
let MAX_CONFIG_SIZE: UInt64 = 1_048_576
let CLEANUP_FAILURE_REMEDY = "The Mac is still set not to sleep. Run `sudo pmset -a disablesleep 0` in Terminal, or launch StayAwake again to restore it."
/// The remedy for the launch that was supposed to be the remedy: it drops the "launch again" half of
/// ``CLEANUP_FAILURE_REMEDY``, which is the advice that just failed.
let RELAUNCH_RESTORE_FAILURE_REMEDY = "A previous quit left the Mac set not to sleep, and this launch could not hand the setting back either. Run `sudo pmset -a disablesleep 0` in Terminal, and check that StayAwake still has permission to run pmset."
/// How long an exiting process waits for a cleanup-failure report to be taken before falling back to a modal.
/// The callers exit on their next statement, so the wait has to be bounded.
let CLEANUP_REPORT_TIMEOUT: DispatchTimeInterval = .seconds(2)
/// How long that fallback modal stays up before the exit continues without a dismissal. Nobody is at the Mac on a
/// logout- or signal-driven exit, so an alert that waits for a click holds the exit open until the OS kills it.
let CLEANUP_ALERT_TIMEOUT: TimeInterval = 5

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

/// Retries the sleep restore that a previous run's cleanup recorded as unfinished.
///
/// - Parameters:
///   - saved: the value the previous run recorded, or `nil` when it left no record.
///   - restore: hands the clamped value back to the Mac; returns whether it took.
/// - Returns: the value the Mac is still owed, or `nil` when there was nothing to restore or the retry succeeded.
///   A non-nil return means the machine still carries the forced-awake setting this app left there, so the value
///   read back from it is this app's own pollution and must never be adopted as the new original.
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

// MARK: - Exit Reporting

/// Blocks until asynchronous work reports back, so a caller about to exit does not die before the work it asked for
/// has been taken.
///
/// A refusal is an answer and returns immediately. Waiting out `timeout` on a channel that has already said no
/// spends the exit window the caller's fallback still needs.
///
/// - Parameters:
///   - submit: receives a callback to invoke exactly once, with whether the work was accepted.
/// - Returns: whether the work was accepted. `false` covers both a reported refusal and `timeout` elapsing — the
///   caller falls back either way, it just reaches the fallback sooner in the first case.
func waitForReport(within timeout: DispatchTimeInterval, _ submit: (@escaping (Bool) -> Void) -> Void) -> Bool {
    let resolved = DispatchSemaphore(value: 0)
    var accepted = false
    submit { taken in
        accepted = taken
        resolved.signal()
    }
    // Reading `accepted` only after a successful wait is what orders the write on the reporting thread against
    // this read; on the timeout path it is never read.
    guard resolved.wait(timeout: .now() + timeout) == .success else { return false }
    return accepted
}

/// Submits a report to the notification centre and reports whether it will actually reach the user.
///
/// Two things have to hold and neither is knowable at launch: the live settings must say a notification would be
/// presented, and the centre must take the request. Whichever fails, the caller is told so it can fall back —
/// never left to infer a refusal from silence.
///
/// - Parameters:
///   - fetchSettings: yields the live authorization status and alert setting.
///   - add: submits the request, yielding the centre's error when it refused.
///   - completion: receives whether the report will be presented. Called exactly once.
func submitNotificationReport(
    _ request: UNNotificationRequest,
    fetchSettings: (@escaping (UNAuthorizationStatus, UNNotificationSetting) -> Void) -> Void,
    add: @escaping (UNNotificationRequest, @escaping (Error?) -> Void) -> Void,
    completion: @escaping (Bool) -> Void
) {
    fetchSettings { authorizationStatus, alertSetting in
        guard notificationCanPresent(authorizationStatus: authorizationStatus, alertSetting: alertSetting) else {
            completion(false)
            return
        }
        add(request) { error in completion(error == nil) }
    }
}

/// Whether a report submitted now would be presented, rather than merely accepted.
///
/// An exit path asks this instead of trusting the authorization captured at launch, which does not survive the user
/// revoking permission or switching alerts off for an app that is still authorized. Acceptance by the notification
/// centre is not delivery, so anything short of a channel that presents belongs in the alert fallback.
func notificationCanPresent(authorizationStatus: UNAuthorizationStatus,
                            alertSetting: UNNotificationSetting) -> Bool {
    authorizationStatus == .authorized && alertSetting == .enabled
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
        // The grant is not recorded: it can be withdrawn afterwards, so every reporter re-reads the live settings
        // at the point it reports rather than trusting an answer from launch.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }

        loadIcons()
        migrateConfigIfNeeded()
        let load = loadConfig()
        config = load.config

        let savedSleep = UserDefaults.standard.object(forKey: "originalSleep") as? Int
        let stillOwed = retryUnfinishedSleepRestore(saved: savedSleep) {
            setSleepPrevention(enabled: false, restoreSleep: $0)
        }
        // Only a retry that succeeded may hand the record over to the machine. While the Mac still carries this
        // app's forced-awake setting, reading it back would store that as the original and every later cleanup
        // would then "restore" the Mac to never sleeping.
        originalSleep = stillOwed ?? getSleepValue() ?? 1
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

        if stillOwed != nil {
            showFailureAlert("StayAwake could not restore sleep settings", RELAUNCH_RESTORE_FAILURE_REMEDY)
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

    /// Binds ``submitNotificationReport(_:fetchSettings:add:completion:)`` to the real notification centre.
    private func submitLiveNotificationReport(_ request: UNNotificationRequest,
                                              completion: @escaping (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        submitNotificationReport(
            request,
            fetchSettings: { yield in
                center.getNotificationSettings { yield($0.authorizationStatus, $0.alertSetting) }
            },
            add: { request, done in center.add(request, withCompletionHandler: done) },
            completion: completion
        )
    }

    /// Notifications can be switched off after launch, and acceptance by the centre is not delivery. Anything
    /// short of a report the live settings say will be presented falls back to an alert. Nothing here is exiting,
    /// so the check needs no bounded wait.
    private func reportSleepControlFailure() {
        let title = "StayAwake could not change sleep settings"
        let body = "Sleep control failed. Check that StayAwake still has permission to run pmset."

        let content = UNMutableNotificationContent()
        content.title = "StayAwake"
        content.subtitle = "Sleep control failed"
        content.body = body
        let request = UNNotificationRequest(identifier: "sleep-failed", content: content, trigger: nil)
        submitLiveNotificationReport(request) { [weak self] presented in
            guard !presented else { return }
            DispatchQueue.main.async { self?.showFailureAlert(title, body) }
        }
    }

    // MARK: Alerts

    /// The only failure channel this app has: it is an LSUIElement, so stderr reaches nobody.
    private func showFailureAlert(_ messageText: String, _ informativeText: String) {
        activateForAlert()
        failureAlert(messageText, informativeText).runModal()
    }

    /// Same alert, but it gives up on the dismissal after `timeout`, for callers whose next statement ends the
    /// process. `runModal` returns only when a human clicks, which is a wait an unattended exit cannot make.
    private func showFailureAlert(_ messageText: String, _ informativeText: String,
                                  dismissingAfter timeout: TimeInterval) {
        activateForAlert()
        let alert = failureAlert(messageText, informativeText)
        // Scheduled in `.modalPanel` so it still fires once the alert has taken over the run loop.
        let dismiss = Timer(timeInterval: timeout, repeats: false) { _ in NSApp.abortModal() }
        RunLoop.main.add(dismiss, forMode: .modalPanel)
        alert.runModal()
        dismiss.invalidate()
    }

    /// Puts the alert in front of the frontmost app's windows. Without this the modal opens behind them: a report
    /// the user never sees is the same silence as not reporting, and the bounded variant takes itself back down,
    /// so being found later is not an option either.
    private func activateForAlert() {
        NSApp.activate(ignoringOtherApps: true)
    }

    private func failureAlert(_ messageText: String, _ informativeText: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        return alert
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

    /// The reporter for the two exit paths the user did not drive. Every channel it uses is bounded, because both
    /// callers end the process on their next statement and a wait that outlives that window is a report nobody sees.
    ///
    /// A notification is preferred — there is no window left to put a modal on — but only once the live settings say
    /// it would be presented, so the report is not handed to a channel the user has since switched off. Anything
    /// else — a refusal, or a request not taken in time — falls through to the alert, which notification settings
    /// cannot suppress, though it is time-bounded and so can still go unread.
    private func reportCleanupFailure() {
        let title = "StayAwake could not restore sleep settings"

        let content = UNMutableNotificationContent()
        content.title = "StayAwake"
        content.subtitle = "Sleep settings not restored"
        content.body = CLEANUP_FAILURE_REMEDY
        let request = UNNotificationRequest(identifier: "cleanup-failed", content: content, trigger: nil)

        let reported = waitForReport(within: CLEANUP_REPORT_TIMEOUT) { resolve in
            submitLiveNotificationReport(request, completion: resolve)
        }
        if !reported {
            showFailureAlert(title, CLEANUP_FAILURE_REMEDY, dismissingAfter: CLEANUP_ALERT_TIMEOUT)
        }
    }

    @objc private func quitApp() {
        if !cleanup() {
            showFailureAlert("StayAwake could not restore sleep settings", CLEANUP_FAILURE_REMEDY)
        }
        NSApp.terminate(nil)
    }
}
