# Vent - menu bar system monitor, fan control, storage scan, keyboard lock

## Context

The user wants a native macOS menu bar app that clones Macs Fan Control and adds system metrics.
Decisions from the user: full fan control (root helper), selectable live metrics in the menu bar, whole-disk largest-files scan (Full Disk Access), native Swift + SwiftUI, and a keyboard lock for cleaning.
The project is greenfield.
Location: `/Users/serenearyal/Documents/projects/misc/vent/` with its own git repo.
"Vent" and bundle id `com.serenearyal.vent` are working names and are easy to change.
Machine: MacBookPro18,3 (M1 Pro), macOS 26.2, Xcode 26.2, Swift 6.2.3, one valid `Apple Development` signing identity, no Developer ID. Team id (certificate OU) is `M9Q5YCJ5NU`; `QG4GX56BVN` in the certificate name is not the team id.

## Facts verified on this machine (read-only probe by the design agent)

- SMC: `IOServiceOpen("AppleSMC")`, `IOConnectCallStructMethod` selector 2, 80-byte struct.
  The key and dataType fields are the native little-endian u32 of the big-endian FourCC; the wrong order gives `0x89` on all calls.
- 2038 SMC keys, full enumeration 0.38 s.
- Fans: `FNum`=2, F0 1200-5779 RPM, F1 1200-6241 RPM, all RPM keys are `flt ` (LE float), mode key is uppercase `F0Md`.
- `Ftst` is absent on M1 Pro, so manual mode is a direct `F0Md=1` write. The `Ftst` retry path stays as a fallback for other chips.
- Temperature keys `Tp0*` (CPU), `Tg0*` (GPU), `Tm0*`, `Ts*P`, `TB0T`, `TW0P`, plus power `PSTR` are readable without root.
- libproc: CPU/memory info fails with EPERM for 66 of 184 processes (root-owned). `PROC_PIDT_SHORTBSDINFO` works for all. The root helper must supply the rest.
- Disk I/O statistics from `IOBlockStorageDriver` are readable without root.
- Data volume is `/System/Volumes/Data` (358 of 494 GB, about 4.4 M inodes). A cold scan is 2 to 6 minutes, so cancel + cache are mandatory.

## Architecture

- **Project definition:** local SwiftPM package `Packages/VentCore` (all logic, no AppKit/SwiftUI, fast `swift test`) + XcodeGen `project.yml` for the app, the helper and integration tests. `brew install xcodegen` is a prerequisite. `*.xcodeproj` is gitignored. A `Makefile` gives `gen / build / test / install`.
- **Modules in VentCore:** `SMCKit` (ABI struct, FourCC, codecs, connection, key catalog, sensor names), `FanControl` (pure curve math, safety clamps, mode-key probe, unlock strategy), `SysMetrics` (CPU via `host_processor_info`, memory via `host_statistics64`, disk space via URL resource values, disk I/O via IORegistry, processes via libproc with CPU deltas and pid-reuse detection, `RingBuffer`), `ScanKit` (bounded min-heap, `fts` walker, coordinator, cache), `HelperProtocol` (XPC protocol, constants, payloads).
- **Menu bar:** `NSStatusItem` with a SwiftUI label rendered by `ImageRenderer` to a template `NSImage`, re-rendered only when the text changes. Not `MenuBarExtra` (no custom layout). `LSUIElement` = true, no Dock icon. A click opens a SwiftUI `Window` with a `NavigationSplitView`: Overview, Fans, Sensors, Processes, Storage, Keyboard Lock, Settings.
- **Root helper:** `SMAppService.daemon` with the plist in `Contents/Library/LaunchDaemons/` and `BundleProgram = Contents/MacOS/VentHelper`. XPC mach service `com.serenearyal.vent.helper`. Both sides set a code-signing requirement (bundle identifier + team OU). Hardened Runtime on, sandbox off. The app always runs from `/Applications/Vent.app` (`make install`) so TCC grants and the daemon path stay stable. Fallback behind the same `HelperInstalling` protocol: `LegacyHelperInstaller` (one admin prompt, installs to `/Library/PrivilegedHelperTools` + `/Library/LaunchDaemons`).
- **Fan control (in the helper):** modes Auto (`F%dMd=0`, `F%dTg=0`), constant RPM, sensor curve (start temp / max temp, linear, 0.5 C hysteresis, 200 RPM/s slew limit, 2 s loop). Clamp to `F%dMn`/`F%dMx`. Thermal interlock: any CPU/GPU sensor above 100 C forces Auto.
  Restore-Auto guarantees: (1) XPC invalidation/interruption with no clients left, (2) SIGTERM/SIGINT/SIGHUP + `atexit`, (3) unconditional Auto at helper start, (4) Auto on sleep and re-apply on wake (`IORegisterForSystemPower`).
- **Processes:** local libproc pass + helper `processSnapshot()` for EPERM pids. Memory = `ri_phys_footprint`. Top lists by CPU and by memory. No `ps`/`top` parsing.
- **Storage:** volumes with used/total (for example "358 GB of 494 GB") and I/O throughput. Largest-files scan: `fts_open` on `/System/Volumes/Data` with `FTS_PHYSICAL | FTS_XDEV` (prevents firmlink double count), `setiopolicy_np(...MATERIALIZE_DATALESS_FILES_OFF)` first so iCloud files do not download, skip `SF_DATALESS`, rank by allocated size (`st_blocks * 512`), top 500 in a min-heap, dedicated thread, progress stream at 10 Hz, cancel, JSON cache with timestamp. Actions: Reveal in Finder, Move to Trash (never `removeItem`). Banner + deep link when Full Disk Access is missing.
- **Keyboard lock:** `CGEvent.tapCreate(.cgSessionEventTap, .headInsertEventTap, .defaultTap)` with mask keyDown, keyUp, flagsChanged and type 14 (NX_SYSDEFINED, media keys). The callback only returns `nil`. Re-enable on `tapDisabledByTimeout`, plus a 2 s watchdog. Needs Accessibility (and Input Monitoring) permission. Refuse to lock when `IsSecureEventInputEnabled()` is true. Unlock paths: hold-to-unlock button (1.5 s) on a full-screen overlay on each screen, 3x Escape in 2 s, hard auto-timeout (default 60 s, 15-300 s). The tap is removed on terminate. Power button and Touch ID cannot be blocked; this is documented in the UI.
- **Debug CLI `ventctl`:** `dump-keys`, `sensors`, `fans`, `watch`, `procs`, `io`, `scan`, `helper-ping`, `selftest`.

## Batches

Implementation goes to the `ldd:ldd-builder` agent, one batch at a time.
The main session reviews, runs the verification and commits with explicit paths (no Claude attribution lines).
Each batch must end with `make build && make test` green.

- [x] **B0 Skeleton:** git init, tree, `Package.swift` (tools 6.2, macOS 26, Swift 6 mode), `project.yml` (App, Helper, ventctl, integration tests), xcconfig, Makefile, `tasks/todo.md` + `tasks/lessons.md` in the project. The build fails if the signing identity is ad-hoc. Verify: app starts from `/Applications`, no Dock icon, `codesign -dvvv` shows the team and runtime flag.
- [ ] **B1 SMC read core + ventctl:** struct with layout asserts, FourCC, codecs (`flt`, `fpe2`, `sp78`, `ui8/16/32`), connection, catalog, sensor names. Unit tests with the captured byte strings. Verify: `ventctl dump-keys | wc -l` = 2038, sensors and fans match the facts above. No writes.
- [ ] **B2 Metrics engine:** CPU (total + per core, P/E labels checked against `powermetrics`), memory, disk space, disk I/O, processes, ring buffer. Verify against Activity Monitor: CPU within 3 points, memory within 200 MB.
- [ ] **B3 Menu bar + window:** status item, metric selection settings (persisted), Overview tab with history graphs. Verify: no flicker or width jitter, light and dark mode, app idle CPU below 1 %.
- [ ] **B4 Helper + XPC (highest risk):** only `ping` and `readSMC` first. Both installers. Verify: `launchctl print system/com.serenearyal.vent.helper` shows euid 0, the helper relaunches on demand after a kill, an ad-hoc re-signed client is rejected.
- [ ] **B5 Fan control:** helper methods, governor, safety, power watcher, Fans + Sensors UI with curve editor. Exhaustive `FanCurve` tests. Verify in order: constant 2500 RPM reached, back to Auto, **`kill -9` of the app returns fans to Auto in 2 s**, helper SIGTERM returns to Auto, sleep/wake re-applies, curve follows load, out-of-range requests are clamped, after reboot fans are Auto.
- [ ] **B6 Processes:** helper snapshot merge, sortable/searchable table, top CPU and top memory lists, quit/force quit with confirmation. Verify: `kernel_task` and `WindowServer` show real values with the helper, a dash without it.
- [ ] **B7 Storage:** heap, walker, coordinator, cache, volume view, largest-files table. Heap test against brute-force sort. Verify: scan with and without Full Disk Access, cancel in 1 s, UI stays responsive, top result matches `du`, no iCloud download starts.
- [ ] **B8 Keyboard lock:** controller, overlay windows, permission onboarding. Verify manually: all keys and media keys dead, mouse works, all 3 unlock paths work, a short tap does not unlock, app kill restores the keyboard, still locked after 5 minutes, refuses during Secure Input.
- [ ] **B9 Hardening:** launch at login (`SMAppService.loginItem`), first-run permission onboarding, `Logger` with privacy annotations, crash matrix (kill, logout, restart for each fan mode and lock state), README.
- [ ] **Review section** added to `tasks/todo.md` at the end.

Estimate at AI agent speed: about 30-60 minutes of agent work for each batch, B4 and B5 longer because of manual hardware checks.
Your actions that I cannot do: admin password / Login Items approval for the helper, Accessibility + Input Monitoring + Full Disk Access grants, and the physical keyboard check in B8.

## Verification (end to end)

- `swift test --package-path Packages/VentCore` for pure logic, `xcodebuild test` for read-only hardware integration tests.
- `ventctl selftest` runs the B5 fan sequence with temperature guards and prints a pass/fail table. Run it after each change to fan code.
- UI checks with screenshots of the menu bar label and each tab in light and dark mode, with attention to pixel-level alignment.
- Cross-checks: Activity Monitor (CPU, memory, processes), `sudo powermetrics --samplers smc` (fan RPM), `du` (largest files).

## Main risks

- Fans left in manual mode or set too low: four restore paths, clamps, 100 C interlock, no 0 RPM outside debug builds.
- `SMAppService` refuses the Apple Development certificate: legacy installer is built in B4, same protocol.
- TCC grants break when the app path or signature changes: always install to `/Applications`, never ad-hoc sign.
- Private SMC writes make the app not eligible for the App Store: direct distribution only.
