# Round 4 - curve bug, bug sweep, folder rename

Asked by the user on 2026-09-22: rename the folder to the current name, fix the sensor-based curve (start 60 C, sensor 50 C, fan at about 1200 rpm), sweep for bugs, fix them and push.

## Root cause of the curve bug
- Below the start temperature `FanCurve.targetRPM` gave the fan minimum (about 1200 rpm), and the governor forced the fan to that speed.
- Under Auto the firmware stops the fan at idle, so the curve made a cool Mac louder than Auto.
- Fix: below the start the governor hands the fan to the firmware and keeps the wish; it takes the fan at the start and lets go `Fans.curveReleaseCelsius` (2 C) below it.

## Wave 0 (main session)
- [x] Curve fix in `FanCurve`, `FanSmoother`, `FanGovernor`, tests, caption and plot in `FansView`.

## Wave 1 (five builders in parallel, cut by file ownership)
- [ ] A helper fans: `suspended` cleared on every wake, `setMode` reports a read error, timer stops after a tick that leaves every fan in Auto, `Ftst` back to 0 when no fan is forced, `setAuto` without a read-back wait, fake hardware idles at 0 rpm in Auto. | owns: Packages/MacToolsCore/Sources/FanControl/* (not FanCurve, FanSmoother), Helper/*, their tests
- [ ] B app fans: stored modes sent again after every new helper connection, the UI shows the mode the helper holds and a fault resets the stored mode. | owns: App/Model/FanStore.swift, App/Helper/*, App/Views/FansView.swift, App/MenuBar/PopoverFans.swift
- [ ] C windows, keyboard, backlight: destination screen for the re-pin, AX messaging timeout, Escape chord stops the tap on the tap thread, slow tap install, Accessibility refresh on activation, `@Sendable` CoreBrightness block. | owns: App/Windows/*, App/KeyboardLock/*, App/Backlight/*, App/Model/SetupChecklist.swift
- [ ] D model and metrics: fresh process sample for a report, settings decode that survives an unknown value, freed total after a partial trash, CPU delta minimum, `takeUnretainedValue`, quit path without a main-thread wait, per-device disk baselines with a monotonic clock. | owns: App/Model/* (not FanStore, SetupChecklist), App/Power/*, Packages/MacToolsCore/Sources/SysMetrics/*, their tests
- [ ] E build, CLI, tests: `install` restart pattern and wait limit, project regenerated when `project.yml` changes, local signing override documented, unnotarized DMG name, `awake hold` overflow, `fan-probe` guard, backlight extra arguments, usage text, integration tests that do not depend on the machine. | owns: Makefile, README.md, docs/DEVELOPMENT.md, Config/*, mactoolsctl/*, Packages/MacToolsCore/Sources/AwakeKit/*, Tests/MacToolsIntegrationTests/Scan*, SMCHardware*

## Wave 2 (main session)
- [ ] Full gates: package tests, `make test`, zero Swift warnings.
- [ ] Version 0.1.2 (build 6), Release install, restart check.
- [ ] Commits by area, push.
- [ ] Rename the folder `misc/vent` to `misc/mactools`, `make clean`, build again from the new path.
- [ ] The user reinstalls the helper (password), then checks the curve: start 60 C, sensor 50 C, fan at 0 rpm.

## Review
