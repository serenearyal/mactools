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

- [ ] **R1 Shell + IA:** popover 400 pt with tabs (Windows and Tools rows as stubs), sectioned sidebar with the 3 new tabs, Hide to Menu Bar button, first-close tip, Show Dock icon setting, per-tab `SamplingPlan`. Key files: `App/MenuBar/MenuBarPopoverView.swift` (split into shell + sections), `MenuBarPopoverController.swift`, `App/Model/MainTab.swift`, `SamplingPlan.swift`, `App/Views/MainWindowView.swift`, `Settings.swift`, `AppDelegate.swift`.
- [ ] **R2 Copy for AI:** `ReportKit` + golden tests, `ventctl report`, toolbar menus, context menus, popover and status menu entries. Reuse `Fmt` (`App/Model/Formatting.swift`), `ProcessStore`, `StorageStore`, `ProcessTable`.
- [ ] **R3 Keep Awake:** `AwakeKit`, controller, tab, popover row, header state, quit-path release, `ventctl awake`.
- [ ] **R4 Keyboard Backlight:** `BacklightKit`, client, tab, popover row, `ventctl backlight`, Release-build gate (no library-validation entitlement).
- [ ] **R5 Window geometry:** `WindowKit` with about 120 pure tests. No system calls.
- [ ] **R6 AX mover + hotkeys:** `App/Windows/*`, conflict detection, `ventctl window list`, Debug-only bundled `VentAXProbe` app for integration tests (never a user window).
- [ ] **R7 Windows UI:** shared `WindowTileGrid` for the popover and the tab, shortcut table with set picker and per-binding status, gap slider.
- [ ] **R8 Efficiency:** the measures above, `scripts/measure_idle.sh`, budgets green in Release.
- [ ] **R9 Polish + docs:** full visual sweep of the popover and all tabs at 900x600 and 760x480, README, `tasks/todo.md` review section, correct the stale Accessibility note.
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
