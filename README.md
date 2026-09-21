# Vent

A native macOS menu bar monitor for an Apple silicon Mac.
It shows live metrics in the menu bar, reads every SMC sensor, controls the fans through a root helper, finds the largest files on the disk and locks the keyboard so you can wipe it.

Vent is written in Swift 6 and SwiftUI, has no dependencies outside the system frameworks, and is built for one machine class: an Apple silicon Mac running macOS 26 or later.

- **Menu bar.** Any of ten metrics, in the order you choose, with a fixed width so the numbers never shift, and a popover with the whole machine behind one click.
- **Overview.** CPU with per-core bars, memory, disk space and throughput, temperatures, fan speeds and system power.
- **Fans.** Auto, a constant speed, or a curve that follows a sensor, with clamps and a thermal interlock.
- **Sensors.** All 2038 SMC keys of a MacBookPro18,3, named and grouped.
- **Processes.** The full table, including the processes you do not own, with Quit and Force Quit.
- **Storage.** Volumes with live read and write, and a whole-disk scan for the 500 largest files.
- **Keyboard Lock.** Every key dead for as long as you need, with three ways out.

## Build

```sh
brew install xcodegen   # once
make gen                # regenerate Vent.xcodeproj from project.yml
make build              # Debug build into build/
make test               # unit tests and integration tests
make release            # optimised build, signature check, size
make install            # build and copy to /Applications/Vent.app
make install CONFIG=Release   # the same, from the Release build
```

`Vent.xcodeproj` is generated and is not in git.
Every target is signed with the one `Apple Development` identity of this machine, and the build fails if that turns into ad-hoc signing.

There is no Developer ID certificate here, so nothing is notarized.
The Release build runs on this Mac because it was built on it; on any other Mac Gatekeeper refuses it.
Distribution would need a Developer ID Application certificate and a notarization pass, and neither exists yet.

### Install

```sh
make install CONFIG=Release
open /Applications/Vent.app
```

Vent must run from `/Applications/Vent.app`.
The launch daemon is registered with the path of the bundle that registered it, and every privacy grant - Accessibility, Input Monitoring, Full Disk Access - is bound to the same path.
A copy that runs from the Downloads folder or from `build/` collects a second set of both and loses them again the moment it moves.
Vent says so in an orange banner above every tab and changes nothing by itself: moving an app behind the user's back is worse than a line of text.

Vent has no Dock icon and no menu of its own.
A click on the menu bar item drops down a popover with the live numbers, and the window opens from the **Open Vent** button in it.
Closing the window leaves the app running.

## First run

The Overview opens with a **Setup** card at the top.
It has one row for each thing Vent asks the system for, with its live state, one line about what it unlocks, and one button that goes where the grant is made.
Every one of them is optional: Vent runs, samples and draws without any of them.

| Row | What it unlocks | Where it is granted |
|-----|-----------------|---------------------|
| Privileged helper | Fan control, and the CPU and memory of processes you do not own | The Install button, then System Settings > General > Login Items & Extensions |
| Accessibility and Input Monitoring | The keyboard lock | The system prompt, then System Settings > Privacy & Security |
| Full Disk Access | A storage scan that reads every folder | System Settings > Privacy & Security > Full Disk Access |
| Launch at login | Vent starts with the session | The toggle in Settings, or the checklist row |

The rows refresh by themselves every time Vent comes back to the front, because all four are granted outside the app and macOS tells no one when they change.

**Dismiss** hides the card and remembers it.
**Settings > Startup > Show setup checklist** brings it back at any time.

### Why each one

- **The helper.** Only root may write to the SMC, so a fan cannot be set without a process that runs as root. The same process reads the CPU and memory counters that libproc refuses for about 219 of the 580 processes on a running Mac.
- **Accessibility.** An event tap that swallows keys is a privilege macOS reserves for apps the user has trusted.
- **Input Monitoring.** A tap that sees key codes needs its own grant; without it the tap exists and receives nothing.
- **Full Disk Access.** Without it the scan still runs, but it cannot read the protected folders - Mail, Messages, Safari, the Time Machine store - and counts them as unreadable. macOS also puts up a consent prompt per protected folder for an app without it, which is the other reason to grant it once.
- **Launch at login.** Vent only measures while it runs. Without the login item the menu bar is empty after a restart until you open the app by hand. It is an `SMAppService.mainApp` registration, so no password is asked; macOS can put it in "needs approval", and the row then links straight to Login Items & Extensions.

## The menu bar item

A left click drops down the popover, a right click opens a small menu: Open Vent, Fans: Full Blast, Fans: Auto, Lock Keyboard, Settings, Quit Vent.
A second left click, a click anywhere else or Escape closes the popover again.

### The popover

340 pt wide, the whole machine at a glance, and no window in sight.

| Section | What it shows | What the title opens |
|---------|---------------|----------------------|
| CPU | Total load, a sparkline of the last minutes, a bar per core with the E and P clusters apart | Overview |
| Memory | Used of total, the pressure dot, the app / wired / compressed / cached bar, free and swap | Overview |
| Storage | Used of total on the boot volume, the bar, free space and the read and write throughput | Storage |
| Thermals & Fans | Hottest CPU sensor, GPU, system power, and each fan with its mode and speed | Fans |
| Top Processes | The three heaviest by CPU and by memory | Processes |

The header has **Open Vent**, **Settings** and **Quit**, and a badge slot that shows **Awake 42m** while Keep Awake holds an assertion.
The **Tools** section holds one row each for Keep Awake, Keyboard Backlight, Fans, Keyboard Lock, Copy for AI and Scan Storage, in that order; the rows share the fixed height of the panel between them, so a Mac with no keyboard backlight gets five slightly taller rows rather than a hole.
**Auto** and **Full Blast** set every fan at once, and are disabled with one line of explanation while the helper is not installed.
Every button that leads somewhere closes the popover first.

While the popover is open, Vent samples exactly as it does with the window open: metrics at the refresh interval, processes every 3 s, fans every 2 s.
It gives all of that up when the popover closes, and an idle Vent with nothing on screen is back to about 0.6 % of one core.
The popover opens on the last numbers it had, so there is no empty frame and no jump when the first fresh sample lands.

The label is a SwiftUI view rendered into a template image, so the system paints it for light and dark mode.
Each metric gets a fixed cell width, computed from the widest string it can ever show, so the item never jitters while the numbers change.

**Settings > Appearance > Show in menu bar** has two positions.

- **Metrics**, the default: the chosen metrics, in one or two lines, with or without the fan symbol.
- **Icon only**: the fan symbol alone, about 36 pt wide against the 95 pt of two two-line metrics. A notched Mac hides everything that does not fit behind the notch without a word, and this is the way back for a menu bar that is full.

Both numbers are measured by the capture path, which writes the rendered label width and the width of the status item: the icon alone renders 20 pt and the system adds 16 pt of padding, and the default two metrics render 79 pt for a 95 pt item.
The doc comment on `MenuBarContent` in `App/Model/Settings.swift` quotes the same two numbers.

The window keeps showing every metric either way.

## The privileged helper

Fan control, and the CPU and memory of processes the user does not own, need a daemon that runs as root.
Vent ships one, `VentHelper`, inside the app bundle and talks to it over XPC on the mach service `com.serenearyal.vent.helper`.
Both sides check the other's code signature: identifier plus the team OU `M9Q5YCJ5NU`, never an entitlement, so the same requirement holds for a debug and a release build.

### Install

Open Vent, go to the Settings tab and press **Install** in the "Privileged helper" section, or press Install in the setup card.

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

Quitting the app also asks the helper to restore Auto directly, before the connection goes away, and waits at most one second for the answer.
The four guarantees above are what covers a crash.

### The CLI

```sh
ventctl fan-status              # fans, limits, modes, faults, interlock state
ventctl fan-set 0 2500          # force fan 0 to 2500 rpm, clamped
ventctl fan-set 0 2500 --hold   # the same, held until Ctrl-C, status every 2 s
ventctl fan-auto 0              # one fan back to the firmware
ventctl fan-auto                # every fan back to the firmware
ventctl selftest-fans           # the gentle live sequence below
```

`fan-set` on its own exits at once, and guarantee 1 above then applies: the connection closes, the last client is gone and the helper puts the fan back on Auto.
The command says so in a note, so a speed that lasted milliseconds does not look like a command that did nothing.

`--hold` is the way to hold a speed from the terminal.
It keeps the XPC connection open, prints the fan every 2 s, and restores Auto on Ctrl-C, on an error and on every other way out.

```
$ ventctl fan-set 0 3000 --hold
fan         rpm     min     max     target   hw       mode
Fan 1       2496    1500    5400    3000     forced   constant 3000 rpm

holding the connection open; the mode lasts until Ctrl-C, which restores Auto
2 s     2731 rpm    target 3000   forced   constant 3000 rpm
4 s     2984 rpm    target 3000   forced   constant 3000 rpm
^C
interrupted: restoring Auto
```

With Vent running there is a second client, so the fan keeps the mode after a bare `fan-set` as well - until the app writes its own stored mode back, which it does within seconds.
The Fans tab is the place to set a mode that should last.

## Windows

Vent tiles the window that was in front: halves, corners, thirds, two thirds, maximize, almost maximize, maximize height, center, restore, larger, smaller and the move to the next or the previous display.
The Windows tab and the Windows section of the popover draw the same grid of miniature screens; a click moves the window, and from the popover the app you were in comes back to the front.
Pressing the same tile again walks a ladder, the way Rectangle does: a half becomes two thirds, then one third, then the half again, and the thirds walk first, center, last.
The ladder starts over after two seconds or as soon as you move the window yourself.

**Gap** (0 to 40 pt) is the space between two tiled windows and between a window and the screen edge.
Two neighbours are exactly one gap apart, whatever the rounding, and the tiles in the grid show the gap you chose.

### The two shortcut sets

| Set | Tiles | Extras |
|-----|-------|--------|
| Rectangle layout | ⌃⌥ + key | ⌃⌥⌘ + key |
| Alternate layout | ⌃⌥⇧ + key | ⌃⌥⇧⌘ + key |

The keys are Rectangle's: arrows for the halves, U I J K for the corners, D F G for the thirds, E and T for the two thirds, C to center, ↩ to maximize, ⌫ to restore, - and = to resize, ↑ for maximize height and ⌃⌥⌘ arrows for the displays.
**Shortcuts start off.** You pick a set in the Windows tab, and every action has a switch of its own next to its chord.

### When another window manager runs

Vent looks for Rectangle, Hookshot, Magnet, Moom and BetterSnapTool by bundle identifier and names the one it finds, with its version, in a banner: use Vent's alternate set, quit that app, or keep Vent's shortcuts off.
Quitting only ever happens on that click, and it is an ordinary quit, the same as Command-Q.

Measured on macOS 26: `RegisterEventHotKey` answers `eventHotKeyExistsErr` only for a chord the **same process** already holds.
Two apps may claim one chord, both are told "registered", and both then answer the key.
So the per-binding dot in the shortcut table is green for a chord this build really claimed, orange while a known window manager is running on Rectangle's own layout (both apps may answer), grey when the action is off, and red when macOS refused the chord outright.

### Permissions

Moving another app's window needs **Accessibility**, the same grant the keyboard lock uses.
Without it the tab and the popover section show one row with a Grant button and nothing else.
The grant is bound to the code identity of the bundle, so a Vent built somewhere else than `/Applications/Vent.app` inherits it only while it is signed the same way.

### What is refused, and why

| Refusal | What you see |
|---------|--------------|
| Full screen | "This window is in full screen. Leave full screen first." |
| Minimized | "This window is in the Dock. Open it first." |
| Not a standard window | A panel, a popover or a status window cannot be tiled. |
| Not movable | The app nailed its window down: the position or the size is not settable. |
| No window | Nothing was in front, or the app has no window at all. |

An app with a minimum size (a terminal, most editors) is not refused: it keeps the size it insists on, and Vent pins it flush against the edges the layout asked for.
Some apps report their window in a space of their own while `AXEnhancedUserInterface` is set; Vent switches that flag off around the write and back on afterwards, never while VoiceOver is running, and the Windows tab has a switch for it.

### The self test

```sh
make window-selftest
```

It builds `VentAXProbe`, a tiny accessory app with one almost invisible window that never takes the focus, launches it without activating it, and drives every action, both ladders, larger, smaller, restore and the minimum-size case against it.
Each result is compared with `WindowKit`'s own answer to the point, and the table is printed and written to `build/selftest/window-selftest.txt`.
No window of yours is ever touched: every move goes to the probe window, found by the title the run generated.

```sh
ventctl window list     # the windows of the frontmost app, read only
```

`ventctl` needs the Accessibility grant on the terminal that runs it, and says so when it is missing.

## Keyboard lock

Vent can hold the whole keyboard for a moment so you can wipe it.
Press **Lock Keyboard** in the Keyboard Lock tab, in the menu bar popover, or in the menu bar item's right-click menu.
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

### Emergency

The keyboard cannot stay locked after Vent is gone: the lock is an event tap owned by the process, and macOS drops it when the process ends.

1. Move the mouse and hold the unlock button, or press Esc three times.
2. Quit Vent from the menu bar item with the mouse, or force quit it from the Apple menu.
3. Close the lid, or log out from the Apple menu with the mouse.
4. Last resort: hold the power button until the Mac restarts.

The hard timeout runs on a queue of its own and the first thing it does is stop the tap, which needs no main thread.
A main thread that is stuck can therefore not keep the keyboard locked.

### Permissions

The lock needs two grants, both for `/Applications/Vent.app`:

- **Accessibility**, so Vent may hold the keys.
- **Input Monitoring**, so Vent may see the keys it holds.

The Keyboard Lock tab shows both with a **Grant…** button and a link into the matching System Settings pane.
macOS shows its own prompt once per app version; after that only the Settings pane works.
Replacing the app bundle can drop a grant, so check the two rows after a `make install`.

## Storage

The Storage tab shows every mounted volume with its used and free space and the live read and write throughput, and under it the 500 largest files of the data volume.

**Scan** walks `/System/Volumes/Data` with `fts`, physical and without crossing a device, which is what stops the firmlinks from counting the system volume twice.
A cold scan of a 358 GB volume with about 4.4 M inodes takes two to six minutes; it can be stopped at any moment and keeps what it found.
The result is cached with its timestamp, so the tab is full the next time the app starts.

Things worth knowing about the scan:

- **Full Disk Access.** Without it the scan still runs and an orange banner says so. It skips the protected folders and counts them as unreadable, and macOS puts up its own consent prompt for the first file it touches in each of them. One grant removes both.
- **iCloud placeholders are skipped.** The walker sets `MATERIALIZE_DATALESS_FILES_OFF` before it starts and skips every entry with the `SF_DATALESS` flag, so a scan never pulls a file down from iCloud. A file that lives only in the cloud has no size on this disk and does not belong in a ranking of what fills it.
- **Size on disk.** Rows rank by allocated size, `st_blocks * 512`, not by logical size. The "Logical" column is filled only when the two differ by more than a percent, which is how a sparse file, an APFS clone or a compressed file gives itself away.
- **Trash only.** "Move to Trash" is the only thing Vent does to a file, and it asks first. There is no delete: everything it moves can be put back from the Trash. A row whose file is gone since the scan is dimmed rather than removed, so the ranking does not jump under the pointer.

## Copy for AI

Everything the Processes and Storage tables know, as a markdown table with a header that stands on its own, ready to paste into a chat.

The paste opens with a question for the chat model, then one line about this Mac (model, chip, clusters, RAM, macOS, uptime, battery), one line of live totals, and one line that says how many rows of how many the table holds and what "CPU %" means on a ten-core machine.
Without those lines a model has no idea whether 180 % CPU is a runaway process or a normal build.

- **Where.** The "Copy for AI" menu in the Processes and Storage toolbars, "Copy for AI" in either table's context menu, Command-Shift-C on either tab, the `doc.on.clipboard` button in the popover's Top Processes header, the "Copy for AI" row of the popover's Tools section, and "Copy Processes for AI" in the status item's right-click menu.
- **Which rows.** "Copy All" takes the union of the top 40 by CPU and the top 40 by memory, capped at 60, so the 8 GB app sitting at 0 % is in the paste next to the one burning a core. "Copy Selected" takes exactly what is selected, in the order the table had it. Files: the top 100 by size on disk, with the folder each one is in.
- **The two options.** "Include question for the AI" is on by default and is remembered; "Copy as TSV" swaps the markdown table for a tab separated one, for a spreadsheet.
- **A copy with nothing on screen.** The process table only samples while somebody is looking at it, and a CPU percentage needs two passes about a second apart. A copy from the popover or the status item menu takes that pair first and shows a spinner while it does; the memory and disk totals are read in the same moment.
- **Names cannot break the table.** A file called `a|b`, or one with a tab or a newline in its name, is escaped. `~` stands in for this account's home directory and for nothing else.

The same text is on stdout with `ventctl report processes` and `ventctl report files`.

## Keep Awake

Holds this Mac awake with an `IOPMAssertionCreateWithProperties` assertion, `PreventUserIdleSystemSleep`, plus `PreventUserIdleDisplaySleep` beside it when "Keep the display on" is on.

- **Durations:** indefinitely, 30 minutes, 1 hour, 2 hours, 4 hours. The duration is handed to the kernel as the assertion's own timeout with `TimeoutActionRelease`, so it ends even if Vent dies first, and the switch on screen moves itself at the same second through one timer with a tolerance. Nothing polls.
- **Battery guard.** Default on: the assertion is released below 20 % on battery, and the charge has to clear the threshold by three points before it comes back. The threshold is a stepper from 5 % to 50 %. A critical thermal state releases it whatever the setting says. Only what the guard released may the guard give back - a Keep Awake the user switched off stays off when the Mac is plugged in.
- **The state is never restored.** Vent starts every launch with Keep Awake off, and there is no "turn on at launch" option. A Mac that silently never sleeps because of a setting made weeks ago is a flat battery waiting to happen.
- **Where.** The Keep Awake tab, the "Keep Awake" row of the popover's Tools section, and an "Awake 42m" badge in the popover header. While it is on, the status item's glyph is the filled variant of the same symbol, which is exactly as wide, so the menu bar item does not change size.
- **What it does not do.** It stops the idle sleep that follows a spell of no input. It does not stop a sleep you ask for: the Apple menu, the power button and a closed lid on battery all still sleep this Mac.
- **What else is holding this Mac awake.** The tab lists every assertion on the machine from `IOPMCopyAssertionsByProcess`, with the process, the pid and the type in plain words. It refreshes every five seconds and only while the tab is on screen.
- **`pmset disablesleep`.** When the system-wide `SleepDisabled` setting is 1, the tab says so and offers `sudo pmset disablesleep 0` as selectable text with a copy button. Vent never sets it and cannot undo it: that needs root.

## Keyboard backlight

A slider and an Auto toggle for the built-in keyboard's backlight, through the private `CoreBrightness.framework`.

- **How it is reached.** `dlopen` on the first use, `NSClassFromString("KeyboardBrightnessClient")`, and typed `@convention(c)` pointers from `method_getImplementation`. The type encodings are read off the class at runtime, not guessed. No entitlement is needed: it is an Apple platform binary, so library validation under the hardened runtime allows it, and `codesign -d --entitlements -` on the Release app shows no exception.
- **When the Mac has no such keyboard.** The popover row, the sidebar item and the tab are not drawn at all. A row that is only ever disabled is worse than no row. `--backlight-force-unavailable` makes a Mac that does have one look like one that does not.
- **The ladder.** The slider snaps to the same 16 steps F5 and F6 walk when it is released, so the next key press moves one rung instead of undoing a fraction. Writes during a drag are debounced to about ten a second, last value wins.
- **Auto brightness.** Vent changes it only on an explicit click, in the popover chip or the tab's switch. While Auto is on the slider still works, and a line says the ambient sensor may move it again.
- **The cost.** The value is read at 1 Hz, and only while the Backlight tab or the popover's Tools section is on screen. It goes through the same `SamplingDemand` as the metric samplers, so it stops with the view.

## Efficiency

Vent is a monitor: it is running all day, and the one thing it must never be is the reason the fan comes on.
The budgets below are for the **Release** build on an M1 Pro, measured over a minute with `top`, and `scripts/measure_idle.sh` prints the table.

| State | Budget | This Mac | On wall power, out of Low Power Mode | Before this work |
|---|---|---|---|---|
| Closed - menu bar label only | < 0.5 % CPU | 0.09 % | 0.34 % | 0.79 % |
| Closed - "icon only", or the item parked behind the notch | about nothing | 0.00 % | 0.00 % | 0.79 % |
| Popover open on Dashboard | < 2 % | 1.56 % | 2.43 % | 2.82 % |
| Popover open on Tools | < 2 % | 0.17 % | 0.49 % | 1.34 % |
| Window open on Overview | < 3 % | 0.72 % | 2.12 % | 2.85 % |
| Window open on Processes | < 4 % | 3.50 % | 3.67 % | 4.33 % |
| Window open on Windows (and Keep Awake, Backlight, Settings) | about the closed baseline | 0.09 % | 0.35 % | 0.89 % |

The middle column is the Mac this was measured on, which has Low Power Mode on; the next one is the same build with `--power-rules off`, which is what a Mac on wall power with Low Power Mode off does.
The last column is the build before this work, which had no icon-only rule at all: it sampled for a label nobody could see, so its second row is its first row.
The open Dashboard is the one state that is over its budget there, and the profiler says what is left is SwiftUI laying the panel out again on every pass, not sampling.

Idle wakeups in the closed state: **0.04 per second** (the budget was under 15).
Memory: 15 MB closed, 30 MB with the popover open, 45-67 MB with the window open.

### Where the cost went

- **Nothing on screen means nothing sampled.** With "Show in menu bar: icon only", with no metric ticked, or with a status item the menu bar has no room for - the notch case - the sampler does not run at all. It is not a slower loop, it is no loop.
- **Tolerance on every periodic sleep.** Each `Task.sleep` and each `Timer` carries a fifth of its interval as slack, so the kernel can put the wakeup next to one it was making anyway.
- **The sampling is off the main actor** at `.utility`, on a detached task; only the apply step comes back to the main actor.
- **The menu bar label is drawn straight into a bitmap** (`MenuBarLabelImage`) rather than through `ImageRenderer`: 0.45 ms instead of 1.67 ms, on every pass, for ever. A small LRU keeps the images of the values that come back. The image is the same pixels to the eye at 1x and 2x; `--label-bench` renders both and prints the difference.
- **One observable property per domain.** A CPU-only pass invalidates the CPU card and nothing else, and a value that did not change is not written at all.
- **The process table is filtered and sorted once per sample**, not inside `body`, and the popover reads it every 5 s where its own tab reads it every 3.
- **The sparkline is one `Canvas` and one `Path`**, not a `Chart` with a `LineMark` per sample: 300 marks was the most expensive thing on screen.
- **Temperatures are read at most every 3 s**, and the popover asks for the CPU and GPU dies rather than every labelled sensor. Every sensor is a driver round trip, and a die does not move in a second. The Sensors and Fans tabs are exempt: their charts want every point.
- **Slower on battery** (x2 with nothing on screen), **in Low Power Mode** (x2 on wall power, x4 on battery) and at a serious thermal state (never faster than 5 s), capped at 10 s. Every input is a push notification; nothing polls for it.
- **App Nap stays on.** There is no `beginActivity` anywhere in the app, the helper or the CLI.

### Re-measuring

```sh
make install CONFIG=Release
scripts/measure_idle.sh build/measure/final.txt
```

It launches one extra instance of the installed bundle per state in the background, never takes the front, and only ever kills the pid it started itself: the pid that appeared between two `pgrep` calls around the launch, and only after its command line is checked for that run's tag.
Your own Vent keeps running beside it.

Two states cannot be arranged from outside and have a debug argument for that reason.
`--menu-bar-label on|off` decides whether the label is drawing numbers, because whether the menu bar has room for one more item depends on what else is in it at that second.
`--popover-offscreen` hosts the popover's own view tree in a borderless window one point on screen at the bottom-left corner, because a real `NSPopover` never appears for an app that is not active; it is the same view, the same observation and the same sampling demand, and the one point on screen is what stops AppKit throttling the drawing.

## Launch at login

**Settings > Startup > Launch at login** registers the app with `SMAppService.mainApp`.
No password is asked.
macOS can answer "needs approval", and a line under the toggle then links to Login Items & Extensions, where Vent has to be switched on once.

The toggle reads the live status every time the tab appears and every time Vent becomes active, never a stored boolean: a login item removed in System Settings has to show up as off in the app.

## Uninstall

```sh
open /Applications/Vent.app        # 1. Settings tab > Privileged helper > Uninstall
                                   # 2. Settings tab > Startup > Launch at login, off
                                   # 3. Quit Vent from the menu bar item
rm -rf /Applications/Vent.app
rm -rf ~/Library/Application\ Support/Vent
defaults delete com.serenearyal.vent
```

Do the helper and the login item from inside the app, while it is still there: both are registrations with launchd that outlive the bundle.
`~/Library/Application Support/Vent` holds the scan cache and nothing else.
The defaults domain holds the settings, the fan modes and the window frame.

Nothing is left in `/Library` unless the classic helper install was used, and the Uninstall button removes those two files under one password sheet.
Revoke the privacy grants in System Settings > Privacy & Security if you want them gone as well; macOS keeps them per app, not per file.

## Troubleshooting

**The menu bar item is not there.**
A notched Mac hides the items that do not fit, silently, and Vent has no Dock icon to fall back on.
Launch the app again - from Spotlight, from Finder or with `open -a Vent` - and the window opens instead of a second copy.
Then switch **Settings > Appearance > Show in menu bar** to **Icon only**, which shrinks the item to about a third of its width, or remove a metric.

**The helper says "Needs approval in System Settings".**
That is the normal outcome of the Service Management install, not an error.
Open System Settings > General > Login Items & Extensions, find Vent under "Allow in the background" and switch it on.
The status line goes green by itself when you come back to the app.

**The helper will not register at all.**
Service Management can refuse a daemon signed with an Apple Development certificate.
Press Install again: Vent falls back to the classic installer, which asks for the admin password once and writes `/Library/PrivilegedHelperTools/com.serenearyal.vent.helper` and `/Library/LaunchDaemons/com.serenearyal.vent.helper.plist`.
`sudo launchctl print system/com.serenearyal.vent.helper` shows whether launchd has the job and which euid it runs as.

**The helper is "Running v0.1.0+1, the app is v0.1.0+2".**
The classic install keeps a copy of the binary and that copy goes stale after a rebuild.
An outdated helper is a state of its own: Vent stops calling it, because an older build answers `ping` and then drops the connection on the first method it does not have, which would reach the user as "The helper stopped while it was answering".
Instead the Fans tab, the popover, the Settings section and the setup row all say "The installed helper is v X, this app needs v Y - press Reinstall in Settings".
Press Reinstall.

**A permission was granted and the row is still grey.**
Come back to Vent: the checklist refreshes on activation.
If it stays grey, the bundle macOS granted is not the bundle that is running - check the orange banner and the path in Settings.
Replacing `/Applications/Vent.app` with a build signed by another identity has the same effect, and the fix is to grant it again.

**The fans do not react.**
Fan control needs the helper; the Fans tab says so in a banner with a button to the Settings tab.
A fan on Auto reads 0 rpm at idle, which is the firmware and not a fault.
`ventctl fan-status` prints the modes, the faults and the interlock state in one table.

**The scan is much smaller than the disk.**
Without Full Disk Access it is: the protected folders are counted as unreadable.
The banner above the table says so and links to the right pane.

## Development

```
App/                 the SwiftUI app: menu bar, popover, window, stores, helper client, keyboard lock
Helper/              the root daemon: XPC service, fan governor, power watcher, client auth
ventctl/             the debug CLI
Packages/VentCore/   SMCKit, FanControl, SysMetrics, ScanKit, HelperProtocol - no AppKit
Tests/               integration tests that need a real machine or a real XPC connection
project.yml          the XcodeGen definition; Vent.xcodeproj is generated
```

`Packages/VentCore` holds everything that can be tested without a window, and `swift test --package-path Packages/VentCore` runs in a couple of seconds.
`make test` runs that and then the integration tests: the SMC of this machine read-only, the metrics samplers against the kernel, the scanner against the repository, and the whole XPC path against `HelperService` on an anonymous listener.

No test ever touches the fans of the machine it runs on.
The test target compiles `Helper/HelperService.swift` but not `Helper/HelperServiceDaemon.swift`, and the daemon file is the only place the real `SMCFanHardware` is built, so a test can only ever get `InMemoryFanHardware`.

### ventctl

```sh
ventctl dump-keys | wc -l       # 2038 on a MacBookPro18,3
ventctl sensors                 # named temperatures, power rails, voltages
ventctl fans                    # speeds and limits, read directly
ventctl fan-status              # the helper's view: modes, faults, interlock
ventctl fan-set 0 2500          # lasts only as long as a client is connected
ventctl fan-set 0 2500 --hold   # holds it here until Ctrl-C
ventctl fan-auto
ventctl selftest-fans           # the live sequence, with a temperature guard
ventctl procs                   # the merged process table
ventctl io                      # disk throughput
ventctl scan ~/Downloads        # the walker on one folder
ventctl window list             # the windows of the frontmost app, read only
ventctl helper-ping
ventctl helper-read F0Ac
ventctl report processes        # the Copy for AI text, on stdout
ventctl report files --tsv      # the largest files from the cache, tab separated
ventctl report processes --no-preamble --limit 20
ventctl awake status            # every sleep assertion, and SleepDisabled
ventctl awake hold 30           # the same assertion the app takes, until Ctrl-C
ventctl backlight get           # level, auto, suppressed, dimmed
ventctl backlight ids           # every keyboard, and which are built in
ventctl backlight auto
```

`report files` reads the cache the app and `ventctl scan` write; it never starts a scan of its own.
`backlight` is read only by design: a command that dims the keyboard of somebody looking at another window is not a debugging tool.
`awake hold` names its assertion "ventctl Keep Awake" rather than "Vent Keep Awake", so `pmset -g assertions` tells the CLI and the app apart.

### Debug launch arguments

They exist so a build agent can take a screenshot or drive a tab with no click, and none of them changes what the user chose.

```sh
open -a Vent --args --show-window --tab sensors
  --tab <name>                 open on one tab
  --show-window                open the window at launch
  --show-popover               drop down the menu bar popover at launch, window closed
  --popover-seconds <n>        close the popover again after n seconds
  --setup-checklist hide|show  draw the Overview with or without the setup card
  --processes-sort name        open the process table on another column
  --scan-root <path>           fill the Storage table from one folder
  --overlay-preview <seconds>  draw the lock overlay and create no event tap at all
  --lock-test <seconds>        a real lock, clamped to 10 s
  --copy-report processes|files  run the Copy for AI menu item; overwrites the clipboard
  --keep-awake-test <seconds>  a real assertion with a 1 minute timeout, released after n
  --backlight-probe            log ids, built in, auto and level from the private framework
  --backlight-force-unavailable  draw the app as if this Mac had no keyboard backlight
  --shortcut-set <name>        off|rectangle|alternate for this run, written nowhere
  --window-selftest <app>      drive VentAXProbe through every window action and quit
  --window-selftest-out <dir>  where the PASS/FAIL table is written
  --fake-fans                  a real governor over fans that do not exist
  --fan-mode 0=constant:3000   what a fake fan should do; also curve:Tp01:45:85 and auto
  --window-size 760x480        exact content size, for a shot at the minimum the layout allows
  --no-activate                never take the front: the window is ordered in behind everything
  --window-front               order the window on top without activating (measurement only)
  --popover-offscreen          the popover's view and sampling demand, off the corner of the screen
  --menu-bar-label on|off      pretend the status item label is drawing numbers, or is not
  --label-bench <dir>          time both label renders and write the pixel difference between them
  --capture <dir>              write PNGs and a status file after --capture-delay seconds
  --appearance dark|light      force one appearance
  --capture-quit               quit when the capture is done
```

The capture path writes a status file with the window numbers of the window and of the popover, so a screenshot of either is `screencapture -x -o -l <number>`.
Launch it with `open -g -n /Applications/Vent.app --args --no-activate ...`: `screencapture -l` photographs a window that is behind others, so a capture run never has to take the front from whoever is using the Mac.
The one thing it cannot photograph that way is the real popover: `NSPopover` does not appear for an inactive app, so a run without activation gets the `ImageRenderer` copy instead.
It also renders the popover with `ImageRenderer` into `popover-<appearance>.png`, which needs no Screen Recording grant at all.
That render is the only way to see the popover in the other appearance: the real one is built against the menu bar and follows the system, whatever `--appearance` says.
It is not the way to check the Tools section: a `Menu`, a switch and a `Slider` are AppKit-backed views, and `ImageRenderer` draws a yellow placeholder for each of them, so that section has to be photographed from the real popover window by number.
The same file counts the samples of the three stores, so a popover that left a timer running is one `grep` away.

### Logging

One subsystem, `com.serenearyal.vent`, for the app and the helper together, and one category per feature: `app`, `helper`, `fans`, `lock`, `scan`, `procs`.

```sh
log stream --predicate 'subsystem == "com.serenearyal.vent"' --level debug --style compact
log show --last 10m --predicate 'subsystem == "com.serenearyal.vent" AND category == "fans"'
```

File paths and process names are logged `privacy: .private` and stay redacted unless the user streams the log themselves.
States, counters and error messages are `.public`, because a redacted error is a bug report nobody can read.
There is no `print` anywhere in `App/` or `Helper/`; only `ventctl`, whose output is the point, writes to stdout.

## Manual acceptance checklist

These need a human: an admin password, a physical keyboard, a privacy grant or a power button.
Run them after any change to the helper, the fan code or the lock.

### The helper

- [ ] Settings > Install. Service Management registers the daemon and the status goes to "Needs approval".
- [ ] Turn Vent on in Login Items & Extensions. The status goes to "Running v\<version\> as root" without another click.
- [ ] `sudo launchctl print system/com.serenearyal.vent.helper` shows the job with euid 0 and the mach service.
- [ ] `ventctl helper-ping` answers `pong <version> uid=0`.
- [ ] `sudo launchctl kill SIGKILL system/com.serenearyal.vent.helper`, then `ventctl helper-ping` again: launchd starts it on demand and the answer comes back.
- [ ] An ad-hoc re-signed copy of `ventctl` is refused by the helper.
- [ ] With a helper of an older build installed, the Settings section, the Fans banner, the popover hint and the setup row all say "The installed helper is v X, this app needs v Y - press Reinstall in Settings", and the Fans tab makes no XPC call at all (`log stream --predicate 'subsystem == "com.serenearyal.vent"'` stays quiet).
- [ ] Settings > Uninstall removes it, and the status goes back to "Not installed".

### Fans, live

`ventctl selftest-fans` does steps 1 to 3 by itself, with a temperature guard that aborts and restores Auto if any CPU sensor passes 85 °C.

- [ ] `ventctl fan-set 0 2500 --hold`: the fan reaches about 2500 rpm within 20 s and the status lines keep coming every 2 s.
- [ ] Ctrl-C out of that `--hold`: it prints "restoring Auto", and `ventctl fan-status` shows mode auto and target 0.
- [ ] `ventctl fan-set 0 2500` with Vent not running: it prints the note that the helper has already put the fan back on Auto, and `ventctl fan-status` agrees.
- [ ] `ventctl fan-auto 0`: the mode column goes back to auto and the target to 0.
- [ ] `sudo powermetrics --samplers smc -n 1` agrees with the tab while a fan is forced.
- [ ] `ventctl fan-set 0 99999 --hold` and `ventctl fan-set 0 0 --hold`: both are clamped to the limits of that fan.
- [ ] Set a sensor curve on a CPU sensor and load the machine: the speed follows the ramp and falls back slowly rather than oscillating.
- [ ] Force a fan, then `kill -9` the Vent process: the fans are on Auto within 2 s (`ventctl fans`).
- [ ] Force a fan, then `sudo launchctl kill SIGTERM system/com.serenearyal.vent.helper`: the fans are on Auto.
- [ ] Force a fan, close the lid, wait for sleep, open it: the fan comes back to the mode you chose.

### The keyboard lock, live

- [ ] Lock from the tab. Every letter, every modifier and every media key of the top row is dead in a text editor.
- [ ] Command-Q, Command-Tab and Command-Space do nothing.
- [ ] The mouse and the trackpad still move and click.
- [ ] A short click on "Hold to unlock" does not unlock; 1.5 s does.
- [ ] Esc three times inside 2 s unlocks.
- [ ] The timeout unlocks on its own.
- [ ] Lock, wait five minutes, and the keyboard is still locked and the overlay still counts down.
- [ ] `kill -9` of Vent while locked: the keyboard is back at once.
- [ ] Turn on Secure Keyboard Entry in Terminal and try to lock: Vent refuses and says why.
- [ ] Lock, then close the lid: the lock is gone when the Mac wakes.

### Full Disk Access and the scan

- [ ] Without the grant: the banner is there, the scan finishes, and the unreadable count is not zero.
- [ ] With the grant: the banner is gone and no consent prompt appears during the walk.
- [ ] `du -ax /System/Volumes/Data | sort -n | tail` agrees with the top of the table.
- [ ] Stop during a scan: it stops within a second and keeps what it found.
- [ ] Activity Monitor shows no `bird` or `cloudd` traffic during a scan of a folder with iCloud placeholders.
- [ ] Move a file to the Trash from the table: it is in the Trash, the row is gone and the freed space is in the message.

### The crash matrix

For each fan mode - Auto, constant, curve - and each lock state - unlocked, locked - do all three.
The expected end state is the same every time: the fans are on Auto and the keyboard is alive.

- [ ] `kill -9` of the Vent process.
- [ ] Log out and back in.
- [ ] Restart the Mac.

After a restart, and before Vent is started again, `ventctl fans` shows every fan on Auto.
