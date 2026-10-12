# KeepAwake

Menu bar app for macOS that keeps your Mac awake (lid closed too) for a limited
time, then restores normal sleep automatically. Built for letting AI agents and
long jobs run in the background without forgetting to turn sleep back on.

- Pick **1 / 2 / 3 hours** from the menu bar. Max is 3 hours, enforced in code.
- Auto-off at expiry, **Turn off now**, and Quit all restore sleep.
- While active it also holds power assertions so the screen does not dim or
  idle-lock with the lid open.
- Survives crashes: on next launch it restores sleep or resumes the countdown.

One Swift file, no Xcode project, no dependencies.

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
Durations are the first lines of `KeepAwake.swift`.

## What `install-sudoers.sh` does

Read it before running it. It writes `/etc/sudoers.d/keepawake` so **your user**
can run exactly these two commands without a password, nothing else:

```
/usr/bin/pmset -a disablesleep 0
/usr/bin/pmset -a disablesleep 1
```

That is what lets the app turn sleep back on at expiry while you are away.
The file is validated with `visudo -cf` before install, owned `root:wheel`,
mode `0440`. Remove it any time: `sudo ./install-sudoers.sh --uninstall`.

## Good to know

- Closing the lid turns the screen off and starts the lock countdown. The Mac
  keeps running, but asks for your password after the delay set in
  System Settings > Lock Screen. No app can prevent that without changing that
  setting, which is your call.
- Run it on power, in open air. A closed, busy MacBook gets hot.
- If the app is force-killed while active, sleep stays disabled until you open
  it again (or run `sudo pmset -a disablesleep 0`).
- The app is ad-hoc signed, not notarized. Build it locally rather than
  downloading a prebuilt `.app`, or macOS will block it.
