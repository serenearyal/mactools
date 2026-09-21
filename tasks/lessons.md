# Lessons

Rules from user corrections. Review at session start.

- Every deep link (`x-apple.systempreferences:...`) must have a test that checks the scheme has a handler (`NSWorkspace.urlForApplication(toOpen:)`). A typo in the scheme (hyphen in place of the dot) shipped because only the button was screenshotted, not clicked.
- A button that leaves the app (System Settings, Finder) is not verified by a screenshot. Run the URL with `open` or a test before the batch is reported as done.
- For a clone of a known app, list its presets first (Macs Fan Control has "Full blast") and check each one against the plan.
- Verification runs must not take the focus of the user's machine. Launch GUI checks with `open -g` and a no-activate debug argument, capture windows by window number, batch the captures, and put this rule in every builder prompt that starts the app.

## Agent batches must be small and parallel

- The R8 agent ran 1 h 46 m: one agent, 10 measures, 28 files, 278 serial tool calls, 3 full measurement runs of 9 minutes each, 3 Release installs.
- Rule: give one goal to each agent, and split independent work (separate files) into agents that run in parallel.
- Rule: wall-clock measurements are short (20 s windows) during iterations; the full 60 s run occurs one time at the end.
- Rule: build and install Release one time at the end of a batch, not after each change.
- Rule: only the work that needs the GUI or the measurement stays serial, because of the focus-safety rules.
