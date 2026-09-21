# Round 3 - MacTools: Fans popup tab, Battery on the Dashboard, rename, public release

Decided by the user on 2026-09-21: the name is MacTools; the popup gets a Fans tab with the fan settings; the Dashboard shows a Battery section in place of Thermals and Fans; then a short user README with new screenshots; push to GitHub only after the user approves the README.

## Wave 1 (two builders in parallel, cut by layer)
- [ ] A data: `BatteryReading` + `BatterySampler` in SysMetrics, the battery domain in `MetricsStore`, `SampleRequest.battery`, `PopoverSection.fans`, the popover requests in `SamplingPlan`. | owns: Packages/VentCore/Sources/SysMetrics/Battery*, their tests, App/Model/Metrics*, SamplingPlan.swift, PopoverSection.swift, SamplingPlanTests
- [ ] B interface: Battery section on the Dashboard, the new Fans tab, shell and layout. | owns: App/MenuBar/Popover*.swift except PopoverWindows, PopoverLayoutTests | needs: the contract of A (written in both prompts)

## Wave 2
- [ ] C rename Vent to MacTools everywhere: product, bundle and helper identifiers, mach service, log subsystem, settings migration from `com.serenearyal.vent`, `ventctl` to `mactoolsctl`, package and module names, docs. | owns: the whole tree | needs: A, B

## Wave 3 (main session)
- [ ] Release install, helper reinstall by the user, permissions again.
- [ ] Screenshots with the new name (the main window needs the app active: the user takes two, or allows 30 s of focus).
- [ ] README (short, user-facing), the old README moves to docs/DEVELOPMENT.md, LICENSE (MIT).
- [ ] The user approves the README, then: GitHub repo, push. Developer ID certificate, notarized DMG and a Release come after that.

## Review
(to be written)
