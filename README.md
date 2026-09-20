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
