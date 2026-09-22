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

## A wait loop must not find itself

- The R8 agent left two background loops with `until ! pgrep -f "measure_idle.sh"`. The pattern also matches the loop's own command line, so the loops ran for hours and the agent looked active.
- Rule: wait on a pid (`while kill -0 <pid>`), a pid file or `pgrep -x <name>`. Never use `pgrep -f` with a text that is in the waiting command.
- Rule: when a batch ends, check for leftover processes of the session and stop them.

## A callback from a system framework is on an unknown thread

- The backlight slider crashed the app: the CoreBrightness block ran on a background queue and the code used `MainActor.assumeIsolated`. No test saw it, because no test made a real write, and only a write makes the notification arrive.
- Rule: `assumeIsolated` is only for callbacks whose thread is documented as main (a main-queue observer, a main run loop timer). All other framework blocks hop with `DispatchQueue.main.async`.
- Rule: each feature that writes to hardware gets a self-test that makes one real write and restores the value, and I run it before I say "done".

## A feature that is off by default is a feature that does not work

- The window shortcuts were off until the user selected a set in a tab. The user quit Rectangle, pressed the shortcuts, and nothing occurred.
- Rule: the default is the state that the user expects after the install. Turn a feature off by default only when it is dangerous, and then show the switch where the user looks first.

## Ask what "works" means for the user before the design

- Keep Awake used an idle-sleep assertion. The user's reference was `sudo pmset disablesleep 1`, which also keeps the Mac awake with the lid closed. The two are different features.
- Rule: when the user has a tool or command that they use today, the feature must do at least what that does.

## An install is not done until the running instance is the new binary

- I quit Vent, built for a minute, copied the app and ran `open -g`. Vent had started again during the build, so `open` did nothing and the user stayed on the old build. I told the user that a new option was there, and it was not.
- Rule: `make install` restarts a running installed instance after the copy. Never quit first and build after.
- Rule: after an install, compare the process start time with the binary's modification time before I say "installed and running".

## Take the evidence before you kill the process

- The user's long-running Vent made WindowServer use about 37 points of CPU (43.6 % with it, 7.2 % without it). I saw that only because I stopped it for a measurement, and then the evidence was gone: a new instance did not show the load in 12 different states.
- Rule: when a process looks guilty, first run `sample <pid> 5`, save its window list and its state file, and only then stop it.
- Rule: an efficiency budget for a menu bar app includes WindowServer, not only the app's own CPU. `scripts/measure_idle.sh` must record the WindowServer delta.

## A fan fix is proven on the real fans, with the user's settings

- The first curve fix gave the fan to macOS below the start, and I reported the bug as fixed from unit tests and a fake fan. On the real Mac, macOS kept a fan that had been spinning at about 40 % for minutes, so the user still heard it.
- Rule: "Auto" and "off" are different. A fake fan that idles at 0 in Auto proves nothing about what the firmware does after a forced run.
- Rule: before I say a fan behaviour is fixed, I watch `mactoolsctl fans` on the real Mac in the user's mode for a few minutes, or I ask the user for that one check and say that it is still open.

## A guard must not block the user's own switch

- Keep Awake refused to turn on at 3 % battery, because the battery guard also covered the switch. The user saw a switch that did not work.
- Rule: a safety guard that exists for a forgotten state steps aside for an explicit user action and arms again later. Only a real hazard (heat) refuses a switch.
