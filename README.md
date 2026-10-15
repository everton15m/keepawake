# KeepAwake

Menu bar app for macOS that keeps your Mac awake (lid closed too) for a limited
time, then restores normal sleep automatically. Built for letting AI agents and
long jobs run in the background without forgetting to turn sleep back on.

- Pick **1 / 2 / 3 hours** from the menu bar. Max is 3 hours, enforced in code.
- **Battery floor** (10 / 15 / 20 / 30 / 40 %, default 20): sleep is restored
  when the battery is at or below the floor and not charging, on two readings in
  a row (15 s apart). It refuses to start within 5 points of the floor.
- **Heat guard**: restores sleep if the Mac reports *serious* heat for 3 minutes,
  or *critical* heat immediately. It refuses to start while already hot.
- Timer expiry, **Turn off now** and Quit all restore sleep. While the app is
  running, every automatic stop shows *why* in the menu ("Last auto-off: ... ·
  battery 19%").
- While active it also holds power assertions so the screen does not dim or
  idle-lock with the lid open.
- If the app was killed mid-session, the next launch resumes the countdown (or
  restores sleep if it already ran out).
- If a restore fails (for example the sudo rule was removed) it keeps retrying
  every 30 seconds, and Quit asks before leaving sleep disabled.

One Swift file, no Xcode project, no dependencies.

## Why a battery floor matters

`pmset disablesleep 1` also switches off macOS's own emergency sleep for low
battery and for overheating, so a closed laptop in a bag would otherwise run
until the battery is empty. KeepAwake puts that safety net back, but only while
one of its sessions is active.

## Install

Needs macOS 14+ and the Command Line Tools (`xcode-select --install`, one time).

```bash
git clone <this-repo-url> KeepAwake && cd KeepAwake
./build.sh                    # builds KeepAwake.app
sudo ./install-sudoers.sh     # one time, asks for your password
open KeepAwake.app            # moon icon appears in the menu bar
```

Optional: `ditto KeepAwake.app /Applications/KeepAwake.app`

Rebuild after editing: `./build.sh`, then quit and reopen the app.
Durations, floor choices and thresholds are the first lines of `KeepAwake.swift`.

## What `install-sudoers.sh` does

Read it before running it. It writes `/etc/sudoers.d/keepawake` so **your user**
can run exactly these two commands without a password, nothing else:

```
/usr/bin/pmset -a disablesleep 0
/usr/bin/pmset -a disablesleep 1
```

That is what lets the app turn sleep back on at expiry while you are away.
The file is validated with `visudo -cf` before install, owned `root:wheel`,
mode `0440`.

Note that any process running as your user can use that rule to keep the Mac
awake, outside of a KeepAwake session. The menu bar icon turns into a yellow
outline cup (checked every minute) when that happens.

Uninstall (restores sleep, quits the app, removes the login item and the rule):

```bash
sudo ./install-sudoers.sh --uninstall
```

## Launch at login (optional, off by default)

The menu item writes `~/Library/LaunchAgents/local.keepawake.plist` for **the
copy you are running at that moment**, so turn it on from the final location of
the app (for example after copying it to `/Applications`).

- It takes effect at your **next login**.
- The copy started by login is restarted if it crashes or is killed. A copy you
  open by hand is not supervised.
- It never starts a session by itself.

## Good to know

- Closing the lid turns the screen off and starts the lock countdown. The Mac
  keeps running, but asks for your password after the delay set in
  System Settings > Lock Screen. No app can prevent that without changing that
  setting, which is your call.
- After an automatic stop with the lid closed and no external display, the app
  also asks the Mac to sleep. If your Mac stays awake after a stop, tell me.
- Run it on power when you can, in open air. A closed, busy MacBook gets hot.
- `disablesleep` is a persistent setting. If the app is killed, or the Mac
  crashes or reboots mid-session, sleep stays disabled until KeepAwake runs
  again (or you run `sudo pmset -a disablesleep 0`). Launch at login covers
  the common case.
- Low Power Mode is ignored on purpose: it is a performance setting, not a
  battery emergency. The floor covers the real risk.
- The app is ad-hoc signed, not notarized. Build it locally rather than
  downloading a prebuilt `.app`, or macOS will block it.
