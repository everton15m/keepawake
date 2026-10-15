import Cocoa
import IOKit.pwr_mgt
import IOKit.ps

// MARK: - Config (edit these, then re-run ./build.sh)
let DURATIONS_MIN = [60, 120, 180]   // menu choices, in minutes
let DEFAULT_MIN   = 120              // marked "(default)" in the menu
let MAX_MIN       = 180              // hard cap, enforced in code
let FLOOR_CHOICES = [10, 15, 20, 30, 40]   // battery floor menu choices, in percent
let DEFAULT_FLOOR = 20                     // turn sleep back on at or below this (when not charging)
let START_MARGIN  = 5                      // refuse to start within this many % of the floor
let THERMAL_HOLD  = 180.0                  // seconds "serious" heat must last before auto-off ("critical" is immediate)
let TICK_SECS     = 5.0                    // main timer; the checks below are time-based, so this only sets their precision
let SAFETY_SECS   = 15.0                   // battery + heat check interval while a session is active
let RETRY_SECS    = 30.0                   // retry interval while a restore is failing
let SYNC_SECS     = 60.0                   // how often to look for changes made outside the app

let durations: [Int] = {
    let d = DURATIONS_MIN.filter { $0 > 0 && $0 <= MAX_MIN }
    return d.isEmpty ? [min(60, MAX_MIN)] : d
}()
let defaultMin: Int = durations.contains(DEFAULT_MIN) ? DEFAULT_MIN : durations[0]
let endKey = "endDate"
let floorKey = "floorPercent"
let lastStopKey = "lastStop"

// MARK: - pmset

/// Runs `sudo -n pmset -a disablesleep <v>`. Returns an error string, or nil on success.
/// argv must match the sudoers entry written by install-sudoers.sh exactly.
func runPmset(_ v: Int) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    p.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", "\(v)"]
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    let err = Pipe()
    p.standardError = err
    do { try p.run() } catch { return "\(error)" }
    let data = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    if p.terminationStatus == 0 { return nil }
    let msg = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return msg.isEmpty ? "exit \(p.terminationStatus)" : msg
}

/// A property of the kernel's power-management root domain (no subprocess, no root).
func rootDomainProperty(_ key: String) -> Any? {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard svc != 0 else { return nil }
    defer { IOObjectRelease(svc) }
    return IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

/// Reads the real system state. nil if it can't be determined.
func readSleepDisabled() -> Bool? {
    if let v = rootDomainProperty("SleepDisabled") {
        if let b = v as? Bool { return b }
        if let n = v as? Int { return n != 0 }
    }
    // Fallback: parse `pmset -g`.
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["-g"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let s = String(data: data, encoding: .utf8) else { return nil }
    for line in s.split(separator: "\n") where line.contains("SleepDisabled") {
        if let last = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last { return last == "1" }
    }
    return nil
}

/// Sets the flag and reads it back: exit code 0 alone doesn't prove it changed.
func setSleepDisabled(_ on: Bool) -> String? {
    if !on, readSleepDisabled() == false { return nil }   // already restored: nothing to do, no sudo needed
    if let err = runPmset(on ? 1 : 0) { return err }
    if let now = readSleepDisabled(), now != on { return "pmset ran but the setting did not change" }
    return nil
}

// MARK: - Power / safety inputs

struct PowerInfo { var percent: Int?; var charging: Bool }   // percent nil = no internal battery (or unreadable)

func readPower() -> PowerInfo {
    let none = PowerInfo(percent: nil, charging: false)
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return none }
    for ps in list {
        guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
              (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
              (d[kIOPSIsPresentKey] as? Bool) ?? true,
              let cur = d[kIOPSCurrentCapacityKey] as? Int,
              let mx = d[kIOPSMaxCapacityKey] as? Int, mx > 0 else { continue }
        return PowerInfo(percent: cur * 100 / mx, charging: (d[kIOPSIsChargingKey] as? Bool) ?? false)
    }
    return none
}

func thermalNow() -> ProcessInfo.ThermalState { ProcessInfo.processInfo.thermalState }

func lidIsClosed() -> Bool { (rootDomainProperty("AppleClamshellState") as? Bool) ?? false }

func externalDisplayConnected() -> Bool {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var n: UInt32 = 0
    guard CGGetOnlineDisplayList(16, &ids, &n) == .success else { return false }
    return ids.prefix(Int(n)).contains { CGDisplayIsBuiltin($0) == 0 }
}

/// Asks the Mac to sleep now. Used after an automatic stop with the lid already closed: clearing the flag
/// alone may not make a closed Mac sleep right away, and other apps can hold it awake.
func sleepNow() {
    let port = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
    if port != 0 { _ = IOPMSleepSystem(port); IOServiceClose(port) }
}

// MARK: - Formatting

func label(_ m: Int) -> String {
    if m < 60 { return "\(m) min" }
    if m % 60 == 0 { return m == 60 ? "1 hour" : "\(m / 60) hours" }
    return "\(m / 60)h \(m % 60)m"
}

func fmtRemaining(_ secs: TimeInterval) -> (long: String, short: String) {
    let mins = max(1, Int(ceil(secs / 60)))   // round up so it never shows 0:00 while active
    let long = mins >= 60 ? "\(mins / 60)h \(mins % 60)m" : "\(mins)m"
    return (long, "\(mins / 60):" + String(format: "%02d", mins % 60))
}

// MARK: - Assertions

/// While active, also hold power assertions so the screen doesn't dim, start the screen saver,
/// or idle-lock with the lid open. They are released automatically if this process exits or dies.
/// (Closing the lid always turns the display off and starts the lock countdown; no assertion can stop that.)
final class AwakeAssertions {
    private var systemID = IOPMAssertionID(0)
    private var displayID = IOPMAssertionID(0)
    private var activity: NSObjectProtocol?
    private var isActive = false

    func start() {
        guard !isActive else { return }
        let reason = "KeepAwake: background AI work" as CFString
        let sys = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                              IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &systemID)
        let disp = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                                               IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &displayID)
        if sys != kIOReturnSuccess { systemID = 0 }
        if disp != kIOReturnSuccess { displayID = 0 }
        // Also keeps App Nap from stretching our 1s timer while the app is hidden.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "KeepAwake session")
        isActive = true
    }

    func stop() {
        guard isActive else { return }
        if systemID != 0 { IOPMAssertionRelease(systemID) }
        if displayID != 0 { IOPMAssertionRelease(displayID) }
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
        systemID = 0; displayID = 0; activity = nil
        isActive = false
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var statusLine: NSMenuItem!
    var timer: Timer?
    var sigSources: [DispatchSourceSignal] = []
    let awake = AwakeAssertions()

    var end: Date? {
        didSet {
            if let e = end { UserDefaults.standard.set(e.timeIntervalSince1970, forKey: endKey) }
            else { UserDefaults.standard.removeObject(forKey: endKey) }
        }
    }
    var lastError: String?     // last failed enable (setup missing, etc.)
    var stuck = false          // a disable failed: sleep may still be off; retried every 30s
    var externalOn = false     // sleep disabled by something other than this app's session
    var lastPower = PowerInfo(percent: nil, charging: false)
    var lowReadings = 0        // consecutive readings at/below the floor
    var unreadReadings = 0     // consecutive unreadable battery readings (after one was seen)
    var sawBattery = false
    var hotSince: Date?        // when thermal state first reached "serious"
    var pendingReason: String? // reason of an automatic stop whose restore failed; recorded once the retry succeeds
    var pendingSleep = false   // after that restore succeeds, also ask the Mac to sleep (lid was closed at the stop)
    var quitAnyway = false     // user explicitly chose to quit although sleep could not be restored
    var lastSafety = Date.distantPast, lastRetry = Date.distantPast, lastSync = Date.distantPast
    var lastStatusKey = ""
    let timeFmt: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f }()

    let agentPath = NSHomeDirectory() + "/Library/LaunchAgents/" + (Bundle.main.bundleIdentifier ?? "local.keepawake") + ".plist"

    var floorPercent: Int {
        let v = UserDefaults.standard.integer(forKey: floorKey)
        return FLOOR_CHOICES.contains(v) ? v : DEFAULT_FLOOR
    }

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ n: Notification) {
        // Two copies (e.g. one in /Applications, one in the build folder) would fight over the same state.
        // Lower pid wins, so two racing launches can't both quit.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .contains(where: { $0.processIdentifier < getpid() && !$0.isTerminated }) {
            exit(0)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false   // so "Turn off now" can actually be disabled
        statusItem.menu = menu

        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { [weak self] in
                // Exit code 1 if sleep could not be restored, so a launchd KeepAlive relaunch retries.
                exit((self?.restoreIfNeeded(silent: true) ?? true) ? 0 : 1)
            }
            s.resume()
            sigSources.append(s)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.tick()
            if self.end != nil { self.checkSafety() }   // counts as one battery reading
        }

        // One always-on timer: expiry, safety checks while active, flag sync and stuck-retry.
        let t = Timer(timeInterval: TICK_SECS, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)   // .common so it keeps ticking while the menu is open
        timer = t

        reconcileOnLaunch()
        refreshUI()
    }

    func applicationWillTerminate(_ n: Notification) {
        // Quit via Activity Monitor / AppleEvent / logout comes through here: don't report success if sleep is still off.
        if !restoreIfNeeded(silent: true), !quitAnyway { exit(1) }
    }

    /// Covers crash / kill -9 / power loss: disablesleep survives them, the persisted end date tells us what to do.
    func reconcileOnLaunch() {
        let ts = UserDefaults.standard.double(forKey: endKey)
        let saved: Date? = ts > 0 ? Date(timeIntervalSince1970: ts) : nil
        let sys = readSleepDisabled()
        let now = Date()
        if let s = saved, s > now, sys != false {
            end = min(s, now.addingTimeInterval(Double(MAX_MIN) * 60))   // clamp: never trust a huge stored date
            awake.start()
            checkSafety()   // may already be below the floor after a long crash
        } else if sys == true {
            disable()          // expired or orphaned while the app was down
        } else {
            end = nil          // nothing to restore; clear stale state
        }
    }

    // MARK: actions

    /// Why a session shouldn't start right now, or nil.
    func unsafeReason() -> String? {
        let p = readPower()
        if let pct = p.percent, !p.charging, pct <= floorPercent + START_MARGIN {
            return "Battery is \(pct)% and the floor is \(floorPercent)%. Plug in, or lower the floor in the menu."
        }
        if thermalNow().rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            return "The Mac is running hot. Let it cool down first."
        }
        return nil
    }

    func enable(minutes: Int) {
        if let why = unsafeReason() {
            showAlert("Not starting", why)
            return
        }
        let m = min(minutes, MAX_MIN)
        if let err = setSleepDisabled(true) {
            lastError = err
            refreshUI()
            showAlert("Couldn't keep Mac awake", setupHelp(err))
            return
        }
        lastError = nil
        stuck = false
        lowReadings = 0; unreadReadings = 0; hotSince = nil
        UserDefaults.standard.removeObject(forKey: lastStopKey)
        pendingReason = nil
        pendingSleep = false
        end = Date().addingTimeInterval(Double(m) * 60)
        awake.start()
        lastSafety = Date()
        lastPower = readPower()
        if lastPower.percent != nil { sawBattery = true }
        refreshUI()
    }

    @discardableResult
    func disable(silent: Bool = false, reason: String? = nil) -> Bool {
        awake.stop()
        if let r = reason { pendingReason = r }
        if let err = setSleepDisabled(false) {
            lastError = err
            if let e = end, e > Date() { end = Date() }   // expired date => next launch retries instead of resuming
            stuck = true       // keep the persisted end date so the next launch retries
            refreshUI()
            if !silent {
                showAlert("Couldn't restore sleep", setupHelp(err) + "\n\nOr run:  sudo pmset -a disablesleep 0\n\nKeepAwake keeps retrying every 30 seconds.")
            }
            return false
        }
        end = nil; lastError = nil; stuck = false; externalOn = false
        lowReadings = 0; unreadReadings = 0; hotSince = nil
        recordPendingStop()
        refreshUI()
        if pendingSleep {
            pendingSleep = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { sleepNow() }
        }
        return true
    }

    /// Persists the reason of the last automatic stop (shown in the menu), once it is actually in effect.
    func recordPendingStop() {
        guard let r = pendingReason else { return }
        pendingReason = nil
        let f = DateFormatter(); f.dateFormat = "MMM d, HH:mm"
        UserDefaults.standard.set("\(f.string(from: Date())) · \(r)", forKey: lastStopKey)
    }

    /// An automatic stop (timer, battery, heat). If the lid is already closed and nothing external is
    /// attached, also ask the Mac to sleep, so a bagged laptop doesn't keep running at the floor.
    func autoOff(_ reason: String) {
        // Silent on purpose: a modal alert inside the tick timer would stall the very retry that fixes a failure.
        // The red icon and status line report it instead.
        pendingSleep = lidIsClosed() && !externalDisplayConnected()
        disable(silent: true, reason: reason)
    }

    /// Only touches sudo when there is something to restore. Returns false if a restore was needed and failed.
    @discardableResult
    func restoreIfNeeded(silent: Bool) -> Bool {
        if end != nil || stuck || readSleepDisabled() != false { return disable(silent: silent) }
        return true
    }

    // MARK: ticking

    func tick() {
        let now = Date()
        if stuck {
            if now.timeIntervalSince(lastRetry) >= RETRY_SECS {
                lastRetry = now
                disable(silent: true)   // recovers on its own once sudo works again
            }
            return
        }
        if let e = end {
            if now >= e { autoOff("timer ended"); return }
            if now.timeIntervalSince(lastSafety) >= SAFETY_SECS { checkSafety() }
        }
        if now.timeIntervalSince(lastSync) >= SYNC_SECS { lastSync = now; syncWithSystem() }
        refreshUI()
    }

    /// Battery floor and heat. Two low readings in a row (15s apart) are needed so one odd value doesn't end a session.
    func checkSafety() {
        lastSafety = Date()
        let p = readPower()
        lastPower = p
        if let pct = p.percent {
            sawBattery = true
            unreadReadings = 0
            if !p.charging, pct <= floorPercent {
                lowReadings += 1
                if lowReadings >= 2 { autoOff("battery \(pct)%"); return }
            } else {
                lowReadings = 0
            }
        } else if sawBattery {
            // Had a battery reading earlier and now has none: the safety net is blind, so stop rather than guess.
            unreadReadings += 1
            if unreadReadings >= 3 { autoOff("battery level unreadable"); return }
        }
        switch thermalNow() {
        case .critical:
            autoOff("overheating"); return
        case .serious:
            if hotSince == nil { hotSince = Date() }
            if Date().timeIntervalSince(hotSince!) >= THERMAL_HOLD { autoOff("overheating"); return }
        default:
            hotSince = nil
        }
    }

    /// Notice changes made outside the app (you or an agent ran pmset by hand).
    func syncWithSystem() {
        let sys = readSleepDisabled()
        if sys == false, end != nil || stuck {
            awake.stop()
            end = nil; stuck = false; lastError = nil
            recordPendingStop()
            pendingSleep = false
        }
        externalOn = (end == nil && sys == true)
    }

    // MARK: UI

    func menuNeedsUpdate(_ menu: NSMenu) {
        syncWithSystem()
        lastPower = readPower()
        refreshUI()

        menu.removeAllItems()
        statusLine = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        if end == nil, let last = UserDefaults.standard.string(forKey: lastStopKey) {
            let item = NSMenuItem(title: "Last auto-off: \(last)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        for m in durations {
            let title = "Stay awake \(label(m))" + (m == defaultMin ? " (default)" : "")
            let item = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.tag = m
            menu.addItem(item)
        }
        let off = NSMenuItem(title: "Turn off now", action: #selector(turnOff), keyEquivalent: "")
        off.target = self
        off.isEnabled = end != nil || stuck || externalOn
        menu.addItem(off)
        menu.addItem(.separator())

        let floorItem = NSMenuItem(title: "Battery floor: \(floorPercent)%", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        for v in FLOOR_CHOICES {
            let it = NSMenuItem(title: "\(v)%", action: #selector(pickFloor(_:)), keyEquivalent: "")
            it.target = self
            it.tag = v
            it.state = v == floorPercent ? .on : .off
            sub.addItem(it)
        }
        floorItem.submenu = sub
        menu.addItem(floorItem)

        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = loginEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    func statusText() -> String {
        if stuck { return "⚠ Couldn't restore sleep — retrying (or \"Turn off now\")" }
        if let e = end {
            let r = fmtRemaining(e.timeIntervalSinceNow).long
            var s = "Awake · \(r) left (until \(timeFmt.string(from: e)))"
            if let pct = lastPower.percent, !lastPower.charging { s += " · battery \(pct)%" }
            return s
        }
        if externalOn { return "⚠ Sleep is disabled outside KeepAwake — no timer" }
        if lastError != nil { return "⚠ Setup needed — see install-sudoers.sh" }
        return "Sleep normal"
    }

    func refreshUI() {
        statusLine?.title = statusText()
        if stuck {
            setStatus(symbol: "exclamationmark.triangle.fill", fallback: "⚠", color: .systemRed, title: "")
        } else if let e = end {
            let t = " " + fmtRemaining(e.timeIntervalSinceNow).short
            setStatus(symbol: "cup.and.saucer.fill", fallback: "☕", color: .systemOrange, title: t)
        } else if externalOn {
            setStatus(symbol: "cup.and.saucer", fallback: "☕?", color: .systemYellow, title: "")
        } else {
            setStatus(symbol: "moon.zzz", fallback: "zZ", color: nil, title: "")
        }
        statusItem?.button?.toolTip = statusText()
    }

    func setStatus(symbol: String, fallback: String, color: NSColor?, title: String) {
        guard let b = statusItem.button else { return }
        let key = "\(symbol)|\(title)|\(color?.description ?? "-")"
        if key == lastStatusKey { return }   // don't rebuild the image every second
        lastStatusKey = key
        b.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        b.imagePosition = .imageLeft
        if var img = NSImage(systemSymbolName: symbol, accessibilityDescription: "KeepAwake") {
            if let c = color {
                img = img.withSymbolConfiguration(.init(paletteColors: [c])) ?? img
                img.isTemplate = false
            } else {
                img.isTemplate = true
            }
            b.image = img
            b.title = title
        } else {
            b.image = nil
            b.title = fallback + title
        }
    }

    func setupHelp(_ err: String) -> String {
        let here = Bundle.main.bundleURL.deletingLastPathComponent().path
        let dir = FileManager.default.fileExists(atPath: here + "/install-sudoers.sh") ? here : NSHomeDirectory() + "/KeepAwake"
        return "\(err)\n\nRun once in Terminal:\ncd '\(dir)' && sudo ./install-sudoers.sh"
    }

    func showAlert(_ title: String, _ text: String) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    @objc func pick(_ sender: NSMenuItem) { enable(minutes: sender.tag) }
    @objc func turnOff() {
        pendingSleep = false
        if !stuck {   // while stuck, the pending automatic stop's reason is still the true one
            UserDefaults.standard.removeObject(forKey: lastStopKey)
            pendingReason = nil
        }
        disable()
    }

    @objc func pickFloor(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: floorKey)
        lowReadings = 0
        refreshUI()
    }

    /// A user LaunchAgent (RunAtLoad + relaunch only after an unsuccessful exit): the only way a crash or
    /// kill -9 mid-session gets recovered without you remembering to open the app. Never starts a session.
    /// On only if the agent exists AND points at the copy that is running now (the plist pins an absolute path).
    var loginEnabled: Bool {
        guard let d = NSDictionary(contentsOfFile: agentPath),
              let args = d["ProgramArguments"] as? [String] else { return false }
        return args.first == Bundle.main.executablePath
    }

    @objc func toggleLogin() {
        let fm = FileManager.default
        do {
            if loginEnabled {
                try fm.removeItem(atPath: agentPath)   // an already-loaded copy stays until next logout; harmless
            } else {
                guard let exe = Bundle.main.executablePath else { return }
                let plist: [String: Any] = [
                    "Label": Bundle.main.bundleIdentifier ?? "local.keepawake",
                    "ProgramArguments": [exe],
                    "RunAtLoad": true,
                    "KeepAlive": ["SuccessfulExit": false],
                    "ProcessType": "Interactive",
                ]
                try fm.createDirectory(atPath: (agentPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: URL(fileURLWithPath: agentPath))
                showAlert("Launch at login is on", "At your next login KeepAwake starts from:\n\(exe)\n\nThat copy is restarted if it crashes. A copy you open by hand is not.\nIt never starts a session by itself.")
            }
        } catch {
            showAlert("Couldn't change Launch at login", error.localizedDescription)
        }
    }

    @objc func quitApp() {
        if !restoreIfNeeded(silent: true) {
            NSApp.activate()
            let a = NSAlert()
            a.messageText = "Sleep is still disabled"
            a.informativeText = "KeepAwake couldn't turn sleep back on. If you quit, nothing will retry.\n\nRun:  sudo pmset -a disablesleep 0"
            a.addButton(withTitle: "Keep running")
            a.addButton(withTitle: "Quit anyway")
            if a.runModal() == .alertFirstButtonReturn { return }
            quitAnyway = true
        }
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()   // global: NSApplication.delegate is weak
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
