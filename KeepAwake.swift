import Cocoa
import IOKit.pwr_mgt

// MARK: - Config (edit these, then re-run ./build.sh)
let DURATIONS_MIN = [60, 120, 180]   // menu choices, in minutes
let DEFAULT_MIN   = 120              // marked "(default)" in the menu
let MAX_MIN       = 180              // hard cap, enforced in code

let durations: [Int] = {
    let d = DURATIONS_MIN.filter { $0 > 0 && $0 <= MAX_MIN }
    return d.isEmpty ? [min(60, MAX_MIN)] : d
}()
let defaultMin: Int = durations.contains(DEFAULT_MIN) ? DEFAULT_MIN : durations[0]
let endKey = "endDate"

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

/// Reads the real system state (no root needed). nil if it can't be parsed.
func readSleepDisabled() -> Bool? {
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
        if let last = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last {
            return last == "1"
        }
    }
    return nil
}

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

/// While active, also hold power assertions so the screen doesn't dim, start the screen saver,
/// or idle-lock with the lid open. They are released automatically if this process exits or dies.
/// (Closing the lid always turns the display off and starts the lock countdown; no assertion can stop that.)
final class AwakeAssertions {
    private var systemID = IOPMAssertionID(0)
    private var displayID = IOPMAssertionID(0)
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
        isActive = systemID != 0 || displayID != 0
    }

    func stop() {
        guard isActive else { return }
        if systemID != 0 { IOPMAssertionRelease(systemID) }
        if displayID != 0 { IOPMAssertionRelease(displayID) }
        systemID = 0; displayID = 0
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
    var stuck = false          // a disable failed: sleep may still be off
    var externalOn = false     // sleep disabled by something other than this app's timer

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false   // so "Turn off now" can actually be disabled
        statusItem.menu = menu

        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { [weak self] in
                self?.restoreIfNeeded(silent: true)
                exit(0)
            }
            s.resume()
            sigSources.append(s)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.tick() }

        reconcileOnLaunch()
        refreshUI()
    }

    func applicationWillTerminate(_ n: Notification) {
        restoreIfNeeded(silent: true)
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
            startTimer()
        } else if sys == true {
            disable()          // expired or orphaned while the app was down
        } else {
            end = nil          // nothing to restore; clear stale state
        }
    }

    // MARK: actions

    func enable(minutes: Int) {
        let m = min(minutes, MAX_MIN)
        if let err = runPmset(1) {
            lastError = err
            refreshUI()
            showAlert("Couldn't keep Mac awake", setupHelp(err))
            return
        }
        lastError = nil
        stuck = false
        end = Date().addingTimeInterval(Double(m) * 60)
        awake.start()
        startTimer()
        refreshUI()
    }

    @discardableResult
    func disable(silent: Bool = false) -> Bool {
        timer?.invalidate(); timer = nil
        awake.stop()
        if let err = runPmset(0) {
            lastError = err
            if let e = end, e > Date() { end = Date() }   // expired date => next launch retries instead of resuming
            stuck = true       // keep the persisted end date so the next launch retries
            refreshUI()
            if !silent {
                showAlert("Couldn't restore sleep", setupHelp(err) + "\n\nOr run:  sudo pmset -a disablesleep 0")
            }
            return false
        }
        end = nil; lastError = nil; stuck = false; externalOn = false
        refreshUI()
        return true
    }

    /// Only touches sudo when there is something to restore.
    func restoreIfNeeded(silent: Bool) {
        if end != nil || stuck || readSleepDisabled() != false { disable(silent: silent) }
    }

    func tick() {
        guard let e = end, !stuck else { return }
        if Date() >= e { disable() } else { refreshUI() }
    }

    func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)   // .common so it keeps ticking while the menu is open
        timer = t
    }

    // MARK: UI

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Detect changes made outside the app (e.g. you ran pmset by hand).
        let sys = readSleepDisabled()
        if sys == false, end != nil || stuck {
            timer?.invalidate(); timer = nil
            awake.stop()
            end = nil; stuck = false; lastError = nil
        }
        externalOn = (end == nil && sys == true)
        refreshUI()

        menu.removeAllItems()
        statusLine = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
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
        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    func statusText() -> String {
        if stuck { return "⚠ Couldn't restore sleep — try \"Turn off now\"" }
        if let e = end {
            let r = fmtRemaining(e.timeIntervalSinceNow).long
            let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
            return "Awake · \(r) left (until \(f.string(from: e)))"
        }
        if externalOn { return "Sleep disabled (no timer)" }
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
        } else {
            setStatus(symbol: "moon.zzz", fallback: "zZ", color: nil, title: "")
        }
    }

    func setStatus(symbol: String, fallback: String, color: NSColor?, title: String) {
        guard let b = statusItem.button else { return }
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
    @objc func turnOff() { disable() }
    @objc func quitApp() {
        restoreIfNeeded(silent: false)
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()   // global: NSApplication.delegate is weak
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
