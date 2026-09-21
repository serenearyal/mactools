# Vent round 2 - popup with tabs, Copy for AI, window manager, keep awake, keyboard light, efficiency

## Context

Vent (in `/Users/serenearyal/Documents/projects/misc/vent`) works: metrics, fan control on real hardware, storage scan, keyboard lock, a 340 pt popover.
The user now wants more tools in the same app, with a minimal, clean and intuitive design and very low CPU and battery cost:
- Copy all processes, and the largest files with their folder, as text to paste into an AI chat.
- A Rectangle clone (move and resize windows with shortcuts).
- Keyboard backlight brightness control.
- A keep-awake (prevent sleep) toggle.
- An explicit "Hide to menu bar" button and a larger popup "like a Chrome extension".

Decisions from the user: larger popup with tabs (Dashboard / Windows / Tools), Rectangle default shortcuts, drag-to-edge snapping later, optional Dock icon as the notch fallback.

## Facts verified on this machine (read-only probe)

- **Rectangle 0.73 runs now (pid 881) with launch at login on.** It owns the Ctrl+Opt shortcut set. `RegisterEventHotKey` returns `eventHotKeyExistsErr` for a taken combination, so conflicts can be detected for each binding.
- Carbon `RegisterEventHotKey` compiles under Swift 6.2, needs no TCC permission, consumes the key, and has no cost per keystroke. Rectangle uses the same API.
- Accessibility is already granted to Vent (the note in `tasks/todo.md` is out of date). Input Monitoring is not granted and is not needed here.
- AX geometry: `axY = primaryScreen.frame.maxY - (nsY + height)`, against the primary screen. `AXEnhancedUserInterface` is 1 on iTerm2, Firefox and Preview, so the known offset workaround is necessary (toggle off, move, toggle on; skip when VoiceOver runs). `"AXFullScreen"` and `"AXEnhancedUserInterface"` are raw strings.
- An unbundled binary does not vend an AX server (`kAXErrorNotImplemented`), so window-move tests need a small bundled probe app.
- Keyboard backlight: private `CoreBrightness.framework` loads with `dlopen`; class `KeyboardBrightnessClient` exists with `copyKeyboardBacklightIDs`, `brightnessForKeyboard:`, `setBrightness:forKeyboard:`, `isAutoBrightnessEnabledForKeyboard:`, `enableAutoBrightness:forKeyboard:`, `registerNotificationForKeys:keyboardID:block:`. Read test: keyboard id 95159106, brightness 0.06, built-in, **auto brightness is ON** (the ambient sensor overrides a manual value, so the UI needs an Auto toggle). The Intel `AppleLMUController` is absent. No entitlement is necessary (Apple platform binary); this is proven only at the Release-build gate.
- Keep awake: `IOPMAssertionCreateWithProperties` with `PreventUserIdleSystemSleep` (+ `PreventUserIdleDisplaySleep` for "keep display on"), timeout in the same call. Assertions die with the process, so a crash needs no cleanup. `IOPMCopyAssertionsByProcess` works without root. **`pmset -g` shows `SleepDisabled 1` on this machine already** (set by someone earlier with `sudo pmset disablesleep 1`); Vent will show this and the undo command, and will not offer that switch.
- Only 663 pt of menu bar are left of the notch. `NSStatusItem.isVisible` exists.
- Efficiency audit of the current code: sample loops use `Task.sleep` with no tolerance; samplers inherit main-actor priority; the label re-renders through `ImageRenderer` about 30 times per minute; icon-only mode still samples CPU and temperature; nothing checks if the status item is visible; `MetricsStore.snapshot` is one observable property, so each sample invalidates all popover sections; the Processes table sorts 580 rows inside `body`.

## Design

**Information architecture**
- Popover 400 pt wide, up to 620 pt high, header with Open window / Settings / Quit and a small "Awake 42m" state, segmented tabs:
  - **Dashboard:** today's content (CPU, memory, storage, thermals + fans with Auto / Full Blast, top processes) plus a Copy button.
  - **Windows:** the name of the window that was in front, a 3x3 tile grid (halves, corners, maximize), thirds, Maximize / Almost / Center / Restore / display buttons, gap slider, conflict banner.
  - **Tools:** Keep Awake toggle + duration + options, Keyboard Backlight slider + Auto, Fans, Lock Keyboard, Copy for AI (Processes / Largest files), Scan Storage.
  - Each section keeps a stable height so the popover does not jump. The last tab is remembered.
- Main window sidebar with section headers: **Monitor** (Overview, Sensors, Processes, Storage), **Control** (Fans, Windows, Keep Awake), **Tools** (Keyboard Lock, Keyboard Backlight - hidden when the API is absent), **App** (Settings).
- **Hide to menu bar:** toolbar button "Hide to Menu Bar" (Cmd-W), a one-time tip from the status item on the first close ("Vent keeps running here"), and a setting "Show Dock icon" (`setActivationPolicy(.regular)` + re-activate).

**New pure modules in `Packages/VentCore`** (Swift Testing, no AppKit): `ReportKit`, `WindowKit`, `AwakeKit`, `BacklightKit`.
Everything that touches AX, Carbon, `dlopen` or IOKit power stays in `App/`.
`ventctl` gains `report`, `window list`, `awake`, `backlight get|ids|auto` (read paths) so each system path is testable without the GUI.

**Copy for AI (`ReportKit`)**
- Markdown pipe table with a self-describing header: optional prompt preamble, one line of system context (model, chip, RAM, macOS, uptime, CPU, memory, battery - 6 ms of sysctl), a "top N of M, sorted by ..." line, then rows.
- Processes: union of top 40 by CPU and top 40 by memory (max 60), columns process / pid / user / cpu % / memory / path. Files: top 100, columns file / folder / size on disk / logical / modified.
- `~` abbreviation only for the exact home prefix; `|`, tab and newline in names are escaped; ties broken by pid or path so golden tests are stable; same number formats as the UI (`Fmt`).
- Menu button "Copy for AI" in the Processes and Storage toolbars (Copy all / Copy selected / without preamble / as TSV), context menu entries, popover buttons, status-item menu entry. A copy from the menu or popover takes a one-shot process sample first and shows "Copied 60 processes".

**Window manager (`WindowKit` + `App/Windows/`)**
- Actions: halves, corners, thirds, two-thirds, maximize, almost maximize, maximize height, center, restore, larger, smaller, next / previous display.
- Pure geometry: target frame from action + screen visible frame + gap; repeat-press cycle 1/2 -> 2/3 -> 1/3 (reset after 2 s or when the user moved the window); integer rounding; proportional remap between displays; AX <-> NS flip.
- AX mover: focused window of the last non-Vent app (`FocusTracker` on `NSWorkspace.didActivateApplicationNotification`; the popover captures the app and its focused window before it activates). Refuse full-screen, minimized, non-standard or non-settable windows with a named reason. Write size -> position -> size, re-read, re-pin minimum-size windows. Restore memory (LRU 32).
- Hotkeys: Carbon, Rectangle's default set, with a second conflict-free set on Ctrl+Opt+Shift. Per-binding registration status. When Rectangle (or Magnet, Moom, Hookshot) runs and a binding is taken: banner with "Quit Rectangle", "Use Vent's alternate set", "Turn Vent's shortcuts off". Shortcuts start off until the user picks one, because Rectangle owns them at login today.
- v1 has fixed sets + per-action toggles. The recorder and drag-to-edge snapping are v2 (snapping costs a mouse monitor during each drag, and macOS 26 edge tiling is on by default).

**Keep Awake (`AwakeKit` + `App/Power/KeepAwakeController.swift`)**
- Durations: indefinitely, 30 min, 1 h, 2 h, 4 h. Option "Keep the display on". Battery guard (default: off below 20 % on battery, 3-point hysteresis), and off at critical thermal state. Push notifications only (`IOPSNotificationCreateRunLoopSource`), no polling.
- Status icon variant + "Awake 42m" in the popover header. A list "What keeps this Mac awake" from `IOPMCopyAssertionsByProcess`. One info line when `SleepDisabled 1` is set system-wide.

**Keyboard Backlight (`BacklightKit` + `App/Backlight/KeyboardBacklightClient.swift`)**
- `dlopen` + `NSClassFromString`, cached IMPs with the verified type encodings. Slider (16-step ladder like F5/F6) + Auto toggle; Vent changes the Auto setting only on an explicit user action. Change notifications where they work, else 1 Hz polling only while the slider is on screen. When the API is missing, the row, the sidebar item and the tab are not rendered.

**Efficiency (budgets for the Release build: closed < 0.5 % CPU, popover < 2 %, window < 3 %, idle wakeups < 15/s closed)**
- `Task.sleep(for:tolerance:)` with 20 % tolerance in all loops; samplers at `.utility` priority; per-tab sample requests (the new tabs request nothing); icon-only and hidden status item request nothing; label cache (LRU on the cell strings) and, if still over budget, a direct attributed-string draw in place of `ImageRenderer`; split `MetricsStore` into per-domain observable properties assigned only on change; compute the sorted process rows once per sample; slower cadence on battery (x2), in Low Power Mode (x4) and at serious thermal state; no `beginActivity` (App Nap stays on).
- `scripts/measure_idle.sh`: `top -l 12 -s 5 -pid <pid> -stats cpu,idlew,power` for closed / popover / window states, pass/fail table.

## Batches (each to `ldd:ldd-builder`; main session reviews real screenshots and commits)

- [x] **R1 Shell + IA:** popover 400 pt with tabs (Windows and Tools rows as stubs), sectioned sidebar with the 3 new tabs, Hide to Menu Bar button, first-close tip, Show Dock icon setting, per-tab `SamplingPlan`. Key files: `App/MenuBar/MenuBarPopoverView.swift` (split into shell + sections), `MenuBarPopoverController.swift`, `App/Model/MainTab.swift`, `SamplingPlan.swift`, `App/Views/MainWindowView.swift`, `Settings.swift`, `AppDelegate.swift`.
- [x] **R2 Copy for AI:** `ReportKit` + golden tests, `ventctl report`, toolbar menus, context menus, popover and status menu entries. Reuse `Fmt` (`App/Model/Formatting.swift`), `ProcessStore`, `StorageStore`, `ProcessTable`.
- [x] **R3 Keep Awake:** `AwakeKit`, controller, tab, popover row, header state, quit-path release, `ventctl awake`.
- [x] **R4 Keyboard Backlight:** `BacklightKit`, client, tab, popover row, `ventctl backlight`, Release-build gate (no library-validation entitlement).
- [x] **R5 Window geometry:** `WindowKit` with about 120 pure tests. No system calls.
- [x] **R6 AX mover + hotkeys:** `App/Windows/*`, conflict detection, `ventctl window list`, Debug-only bundled `VentAXProbe` app for integration tests (never a user window).
- [x] **R7 Windows UI:** shared `WindowTileGrid` for the popover and the tab, shortcut table with set picker and per-binding status, gap slider.
- [x] **R8 Efficiency:** the measures above, `scripts/measure_idle.sh`, budgets green in Release.
- [x] **R9 Polish + docs:** full visual sweep of the popover and all tabs at 900x600 and 760x480, README, `tasks/todo.md` review section, correct the stale Accessibility note.
- v2 (not in this round): drag-to-edge snapping with preview, shortcut recorder, hotkeys for backlight and keep awake.

## Verification

- `swift test --package-path Packages/VentCore`, `make test`, zero Swift warnings, for each batch.
- GUI checks never take the user's focus (rule in `tasks/lessons.md`): `open -g -n /Applications/Vent.app --args --no-activate ...`, capture by window number, popover content through the `ImageRenderer` capture path, few launches, quit after each.
- Copy for AI: golden strings; `ventctl report processes` compared with `top`; paste check by the user.
- Keep Awake: `pmset -g assertions | grep Vent` shows the assertion and the timeout; after `kill -9` it is gone.
- Backlight: `ventctl backlight get` follows the slider; the Release app loads CoreBrightness under the hardened runtime; the section disappears with `--backlight-force-unavailable`.
- Windows: geometry tests; AX moves asserted against `VentAXProbe`; per-binding status shows "taken by Rectangle" while Rectangle runs. The user does the live shortcut check after quitting Rectangle.
- Efficiency: `scripts/measure_idle.sh` table green.
- Needs the user: quit Rectangle (and turn off its launch at login) to use Vent's shortcuts; try the shortcuts on real windows; confirm the backlight slider by eye; no helper reinstall is expected in this round (no helper code changes).

## Review

### What was built, batch by batch

- **R1 Shell + IA.** The popover became a 400 x 600 pt panel with a header (Open Vent, Settings, Quit, badge slot) and three tabs on Command-1/2/3; the sidebar grew four section headers and the three new tabs; the window got "Hide to Menu Bar" on Cmd-W, the one-time menu bar tip and the "Show Dock icon" setting; `SamplingPlan` learned to ask per tab and per popover section.
- **R2 Copy for AI.** `ReportKit` with golden tests, a self-describing preamble (this Mac, the live totals, "top N of M"), the union of the top 40 by CPU and by memory capped at 60, the top 100 files, markdown or TSV, and every entry point: both toolbars, both context menus, Command-Shift-C, the popover's Top Processes header, the Tools row, the status item menu and `ventctl report`.
- **R3 Keep Awake.** `AwakeKit` and `KeepAwakeController` over `IOPMAssertionCreateWithProperties`, five durations handed to the kernel as the assertion's own timeout, the display option, a battery guard with hysteresis, the thermal release, the assertion list from `IOPMCopyAssertionsByProcess`, the "Awake 42m" badge, the filled status glyph and `ventctl awake`.
- **R4 Keyboard Backlight.** `BacklightKit` and a `dlopen` client over `CoreBrightness`, the 16-step ladder, the debounced writes, the Auto switch Vent only ever changes on a click, the tab and the popover row that disappear on a Mac without the hardware, and `ventctl backlight`.
- **R5 Window geometry.** `WindowKit`: the target frame for every action, the repeat-press ladder with its two-second reset, the gap arithmetic, the integer rounding, the proportional remap between displays and the AX/NS flip - about 120 pure tests, no system call.
- **R6 AX mover + hotkeys.** The focus tracker, the AX writer with its size-position-size dance and the `AXEnhancedUserInterface` workaround, the named refusals, the restore memory, Carbon hotkeys in two sets with per-binding status, the other-window-manager detection, `ventctl window list`, and `VentAXProbe` with `make window-selftest`.
- **R7 Windows UI.** The shared `WindowTileGrid` for the tab and the popover, the shortcut table with the set picker and a switch per action, the gap slider and the conflict banner.
- **R8 Efficiency.** Tolerant sleeps, sampling off the main actor at `.utility`, per-domain observable properties, the process rows sorted once per sample, the direct label draw in place of `ImageRenderer`, the icon-only and hidden-item rules that stop the loop dead, the power-aware cadence, and `scripts/measure_idle.sh`.
- **R9 Polish + docs.** The popover's last layout cost: the panel and every Dashboard section are fixed frames now, the core bars and the segmented bars are one `Canvas` each instead of a stack of shapes, and the value labels have fixed widths. The two syscalls a pass did not need: the purgeable-space read, which turned out to be the most expensive thing in a pass, now happens once a minute, and a process keeps its executable path until a new pid or a new start time says it is a different process. The visual sweep of every tab at 900 x 600 and 760 x 480 in both appearances and its fixes - the window title that four tabs did not show, the Processes toolbar at the minimum width, the sensor names that all truncated to the same thing, the "Loading…" lines that now say "Sampling…". The README for round 2, and this review.

### The numbers

Release build, an M1 Pro on battery out of Low Power Mode, one minute of `top` per state, `scripts/measure_idle.sh`.
The left column is the real cadence on this Mac (`build/measure/r9.txt`); the right one is `--power-rules off`, the fastest the app ever samples (`build/measure/r9-nolowpower.txt`).

| State | Budget | This Mac | Power rules off | R8 |
|---|---|---|---|---|
| Closed - menu bar label | < 0.5 % | 0.19 % | 0.27 % | 0.34 % |
| Closed - icon only | about nothing | 0.00 % | 0.00 % | 0.00 % |
| Popover on Dashboard | < 2 % | 1.87 % | 1.63 % | 2.43 % |
| Popover on Tools | < 2 % | 0.44 % | 0.48 % | 0.49 % |
| Window on Overview | < 3 % | 1.77 % | 1.78 % | 2.12 % |
| Window on Processes | < 4 % | 2.42 % | 2.71 % | 3.67 % |
| Window on Windows | about the closed baseline | 0.25 % | 0.32 % | 0.35 % |

Every state is inside its budget, which was the one thing R8 could not say: the Dashboard cost 2.43 % with the power rules off and now costs 1.63 %.
The R8 column is that run, so the comparison is like for like.
Three changes took it there: the fixed layout of the panel and its sections, the purgeable-space read throttled to a minute, and the process path cache.
Two runs of the same state on a Mac somebody is working at land about 0.3 points apart, which is the width of the noise around every figure here.
Idle wakeups closed: 0.09 per second. Memory: 15 MB closed, 34 MB with the popover open, 49-66 MB with the window open.
The README's Efficiency section carries the same numbers with the Low Power Mode rule as it stands now (x2 on wall power, x4 on battery).

### What is verified, and how

- **Pure logic** - `swift test --package-path Packages/VentCore` and the app's own test bundle: `WindowKit`'s geometry, the report goldens, the Keep Awake state machine, the backlight ladder, the sampling plan, the popover's layout arithmetic. `make test` runs both.
- **The window mover against a real accessibility server** - `make window-selftest` drives `VentAXProbe` through every action and compares each result with `WindowKit`'s own answer.
- **The system paths that can be read** - `ventctl report`, `ventctl awake status`, `ventctl backlight get|ids|auto` and `ventctl window list` each exercise the same code the GUI uses.
- **The look** - every tab photographed at 900 x 600 and 760 x 480, light and dark, and the three popover sections rendered with `ImageRenderer`, in `build/screenshots/r9/`.
- **The cost** - the measurement table, and `sample` profiles in `build/measure/` for the state that was over budget.

### What is not verified

- Everything under "Round 2, live" in the README: a global shortcut needs a real key press, the backlight needs eyes, Command-W, the Dock icon toggle and a Copy for AI paste need a user at the machine. The shortcut sets are registered and reported per binding, but no key was pressed by this batch.
- The real popover, photographed rather than rendered: `NSPopover` does not appear for an inactive app, and the render draws a placeholder for the switch, the menu and the slider in the Tools section.
- The helper-mismatch and no-helper states of the Dashboard's fan slot: the helper on this machine matches the app, so those two lines were fitted by arithmetic and not photographed.
- A Mac with no keyboard backlight, a second display, and a fan count other than two.

### v2

- Drag-to-edge snapping with a preview. It costs a mouse monitor for the length of every drag, and macOS 26 tiles at the edges by default, so it has to be better than what the system already does.
- A shortcut recorder. v1 ships two fixed sets and a switch per action; recording a chord means a key monitor, a conflict check against every other binding and a way back out of a chord that captured itself.
- Hotkeys for the keyboard backlight and Keep Awake, which need the recorder first: F5 and F6 already move the backlight, so a second way to do it is only worth a chord the user picked.
