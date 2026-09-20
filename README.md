# Vent

A native macOS menu bar monitor for an Apple silicon Mac: live metrics in the menu bar, sensors, fan control, a largest-files scan and a keyboard lock for cleaning.

## Build

```sh
make gen      # regenerate Vent.xcodeproj from project.yml (needs xcodegen)
make build
make test
make install  # build and copy to /Applications/Vent.app
```

The app must run from `/Applications/Vent.app`.
Permission grants and the launch daemon are tied to that path, and moving the bundle breaks both.

## The privileged helper

Fan control, and the CPU and memory of processes the user does not own, need a daemon that runs as root.
Vent ships one, `VentHelper`, inside the app bundle and talks to it over XPC on the mach service `com.serenearyal.vent.helper`.
Both sides check the other's code signature: identifier plus the team OU `M9Q5YCJ5NU`, never an entitlement, so the same requirement holds for a debug and a release build.

### Install

Open Vent, go to the Settings tab and press **Install** in the "Privileged helper" section.

The app tries two paths, in this order.

1. `SMAppService.daemon`, the modern one.
   It asks for no password.
   macOS registers the daemon switched off and the status changes to "Needs approval in System Settings".
   Press **Open Login Items Settings** and turn Vent on under "Login Items & Extensions".
2. If Service Management refuses the daemon, which can happen with an Apple Development certificate, Vent falls back to the classic install.
   One system password sheet appears.
   Accepting it copies the helper to `/Library/PrivilegedHelperTools/com.serenearyal.vent.helper`, writes `/Library/LaunchDaemons/com.serenearyal.vent.helper.plist` and bootstraps the job.

The status line then reads "Running v\<version\> as root".
If the app is newer than the installed helper the line says so and the button becomes **Reinstall**.

### Check it

```sh
sudo launchctl print system/com.serenearyal.vent.helper   # state, euid 0, the mach service
ventctl helper-ping                                       # pong <version> uid=0, over XPC
ventctl helper-read F0Ac                                  # raw bytes of one SMC key
```

`ventctl` is built next to the app, in `build/Build/Products/Debug/ventctl`.
It is signed with the same identity as the app and its identifier is in the helper's client requirement, so it reaches the same service the app does.
A failure that names the signature means the installed helper is not the one this build expects; reinstall it.

### Uninstall

Press **Uninstall** in the same section.
It unregisters the Service Management job and, if the classic install was used, removes both files under one password sheet.

### Logs

```sh
log stream --predicate 'subsystem == "com.serenearyal.vent"' --level debug --style compact
```

Everything about the daemon is logged under the category `helper`, by the helper and by the app, so one stream shows both sides of a call.

## Fan control

The Fans tab lists every fan of the Mac with its current speed between its limits, and gives each one three modes.

- **Auto** hands the fan to the firmware, which is how a Mac behaves out of the box.
  A fan at idle reads 0 rpm in this mode: the firmware stops it, and that is normal.
- **Constant** holds one speed, clamped to the range the firmware reports for that fan (1200-5779 rpm and 1200-6241 rpm on a MacBookPro18,3).
- **Sensor-based** ramps the fan linearly between two temperatures of one sensor: minimum speed below the start temperature, maximum above the full-speed temperature.
  The plot in the card shows the ramp, the current reading and the speed that follows from it.

Fan control needs the privileged helper, because only root may write to the SMC.
Without it the tab still shows the speeds, read directly, and says what is missing.

### Safety

Every path is built so that a fan ends up on Auto rather than stuck.

- **Clamps.** Every setpoint is clamped to `F%dMn`/`F%dMx` before it is written. A request of 99999 rpm becomes the maximum, a negative one the minimum. A fan whose limits did not read back is refused, never written with a guess.
- **Verified writes.** Mode and target are read back after every write. A write the SMC did not take is an error, not a silent no-op.
- **Thermal interlock.** Any CPU or GPU die at 100 °C or above forces every fan back to Auto until the hottest die is below 90 °C. The chosen modes are kept and come back by themselves.
- **Hysteresis and slew.** A curve follows a falling temperature only after it has fallen 0.5 °C, and moves its setpoint by at most 200 rpm per second. A constant speed is applied at once.
- **Fail safe.** A sensor that stops answering, a curve that makes no sense, a write the SMC refuses: that fan goes back to Auto, the reason appears in the tab, and nothing is retried in a loop.

### When the fans go back to Auto

1. **The last client disconnects.** The helper holds a fan only while the app, or `ventctl`, is connected.
   Quitting Vent, and `kill -9` of Vent, therefore returns the fans to Auto within about two seconds.
   A fan curve needs Vent running; Macs Fan Control works the same way.
2. **The helper is asked to stop.** SIGTERM, SIGINT and SIGHUP restore Auto before the process ends, and an `atexit` handler covers every other way out.
3. **The helper starts.** It restores Auto unconditionally before it accepts the first connection, so a helper that was killed mid-curve cannot leave a fan forced across a restart. After a reboot the fans are on Auto.
4. **Sleep and wake.** The fans go to Auto on the way into sleep; the modes are written again once the Mac is awake.

Quitting the app also asks the helper to restore Auto directly, before the connection goes away.
The four guarantees above are what covers a crash.

### The CLI

```sh
ventctl fan-status              # fans, limits, modes, faults, interlock state
ventctl fan-set 0 2500          # force fan 0 to 2500 rpm, clamped
ventctl fan-auto 0              # one fan back to the firmware
ventctl fan-auto                # every fan back to the firmware
ventctl selftest-fans           # the gentle live sequence below
```

### Manual acceptance sequence

Run this after any change to the fan code, with the helper installed and Vent running.
`ventctl selftest-fans` does steps 1 to 3 by itself, with a temperature guard that aborts and restores Auto if any CPU sensor passes 85 °C.

1. `ventctl fan-set 0 2500`, then watch `ventctl fan-status`: the fan reaches about 2500 rpm within 20 s.
2. `ventctl fan-auto 0`: the mode column goes back to auto and the target to 0.
3. Cross-check with `sudo powermetrics --samplers smc -n 1` while the fan is forced.
4. Force a fan from the Fans tab, then `kill -9` the Vent process: the fans are on Auto within 2 s (`ventctl fans`).
5. Force a fan, then `sudo launchctl kill SIGTERM system/com.serenearyal.vent.helper`: the fans are on Auto.
6. Force a fan, close the lid, wait for sleep, open it: the fan comes back to the mode you chose.
7. Set a sensor curve on a CPU sensor and load the machine: the speed follows the ramp, and it falls back slowly rather than oscillating.
8. `ventctl fan-set 0 99999` and `ventctl fan-set 0 0`: both are clamped to the limits of that fan.
9. Reboot: the fans are on Auto until Vent is started again.

### Logs

```sh
log stream --predicate 'subsystem == "com.serenearyal.vent" AND category == "fans"' --style compact
```

Every mode change, every restore and every fault is a line there, on both sides of the XPC link.

## Keyboard lock

Vent can hold the whole keyboard for a moment so you can wipe it.
Press **Lock Keyboard** in the Keyboard Lock tab, or pick "Lock Keyboard" from the menu bar item's right-click menu.
A dark overlay covers every screen and shows the time left.

### What it blocks

Every key press, key release and modifier change, and the media and special keys of the top row (volume, brightness, play).
Nothing typed reaches any app, and no shortcut fires, not even Command-Q or Command-Tab.

### What it cannot block

The power button and Touch ID.
macOS reserves both for the system, so no app can take them; a long press on the power button still forces a restart.
The mouse and the trackpad stay live on purpose: they are how you end the lock.
Vent also refuses to start while another app has Secure Keyboard Entry on, because no app sees the keyboard then and the lock would be a lie.
A password field or a terminal with "Secure Keyboard Entry" in its menu is the usual cause.

### The three ways out

1. Hold the **Hold to unlock** button on the overlay for 1.5 s with the mouse. A short click does nothing, so a cleaning cloth on the trackpad cannot end the lock by accident.
2. Press **Esc** three times inside 2 s.
3. Wait for the timeout. It is 1 minute by default and can be set from 15 s to 5 minutes in the tab.

The lock also ends by itself when Vent quits, when the Mac goes to sleep, when the screen locks and when another user logs in.
Without that last group you could not type your login password.

### Permissions

The lock needs two grants, both for `/Applications/Vent.app`:

- **Accessibility**, so Vent may hold the keys.
- **Input Monitoring**, so Vent may see the keys it holds.

The Keyboard Lock tab shows both with a **Grant…** button and a link into the matching System Settings pane.
macOS shows its own prompt once per app version; after that only the Settings pane works.
Replacing the app bundle can drop a grant, so check the two rows after a `make install`.

### If everything fails

The keyboard cannot stay locked after Vent is gone: the lock is an event tap owned by the process, and macOS drops it when the process ends.

1. Move the mouse and hold the unlock button, or press Esc three times.
2. Quit Vent from the menu bar item with the mouse, or force quit it from the Apple menu.
3. Close the lid, or log out from the Apple menu with the mouse.
4. Last resort: hold the power button until the Mac restarts.

### Logs

```sh
log show --last 5m --predicate 'subsystem == "com.serenearyal.vent" AND category == "lock"'
```

Every lock, every unlock with its reason, and every re-enable by the watchdog is a line there.
