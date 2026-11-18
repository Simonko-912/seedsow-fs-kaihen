# Seedsow FS exploit

Runs kaiHEN on a retail Switch 2 by driving the FS exploit from a Seedsow
Lullaby Demo/Full Game save, then lets you launch homebrew with the usual hold-R shortcut.

Tested on firmware 23.0.1.

---

## What you need

- A Switch 2 with **Seedsow Lullaby Demo/Full Game** installed, with alula's seedsow save.
- A PC on the same network as the console (wifi or ethernet), with **Node.js 20+** on `PATH` (Windows, Linux or macOS).
- The console's SD card inserted (express or non-express).
- Optional: A controller bridge: any program that implements the small HTTP API described below. You can use the automatic retry feature with a controller bridge.

## Setup (once)

1. Copy this folder anywhere on the PC.
2. The repository contains an empty `kaihen/` folder. Let the kit download a
   kaiHEN release, or put one there yourself (see below).
3. Put the console's address in `tools/console-host.txt` (one line, e.g.
   `192.168.1.50`). If the file is missing, copy
   `tools/console-host.example.txt` and edit it, or pass `--ip` to the command
   line runner.
4. Optional: copy `controller-connection.example.json` to
   `controller-connection.json`, set your controller bridge's `host` and `port`,
   and make sure the bridge is running.

## kaiHEN release

The repository contains an empty `kaihen/` folder and does not ship kaiHEN
itself. The kit can download the latest release for you, or you can point it at
a folder you already have.

**GUI:** press **Update kaiHEN (Auto-Download)**. It downloads the latest
release from <https://github.com/ouncebrew/kaihen/releases>, extracts the ZIP
into `kaihen/`, and deletes the ZIP. It works on Windows, Linux and macOS.

**CLI:**

```
node ns2-run.cjs --update-kaihen-latest
```

Both replace the release files, so copy a locally patched `hen/main` or
`bootstrap.bin` aside first if you use one.

If you already have an unpacked release, press **Update kaiHEN (local folder)**
in the controller and choose the folder (the browser uploads it into `kaihen/`),
or run:

```
node tools/update-kaihen.cjs <folder>
```

**Open kaiHEN releases** opens the release page in the browser. `kaihen/` is
git-ignored, so replacing its contents never touches the rest of this repository.

The result must be:

```text
kaihen/bootstrap.bin
kaihen/hbmenu.nro
kaihen/ro/main
kaihen/hen/main
kaihen/game/main
kaihen/programs/...
```

### Updating this kit

**GUI:** press **Check for updates**. If a newer integer version exists, a
**New update found: Vx, download?** button appears. Clicking it refuses while a
run is active; otherwise it downloads the new repository, stops the GUI,
replaces the kit files, keeps `kaihen/`, `runs/`, `env.local.txt` and
`tools/console-host.txt`, updates its own updater script, and restarts the GUI.

**CLI:**

```
node ns2-run.cjs --check-updates   # report whether a newer version exists
node ns2-run.cjs --self-update     # download and apply it
node ns2-run.cjs --version         # print the local version
```

`version.json` contains one integer (`{"version": 1}`). Bump that number when
you publish a new version of this kit.

## Running it

1. Start the controller: **`start-gui.bat`** on Windows, **`start-gui.command`**
   on macOS, **`./start-gui.sh`** on Linux. It opens in your browser.
2. Start **Seedsow Lullaby Demo/Full Game** on the console and press **Y** when the
   launcher asks.
3. Press **Start** in the controller.
4. If a run fails, restart the app and try again. If you fail 8 times in a row, restart your console. If your console is frozen, hold the power button down for 15 seconds, then power it back on.
4. Wait for the run to finish. When the log says **kaiHEN is running**, press
   **HOME** on the console, quit Seedsow, and **hold R while starting a native switch 2 game. After it loads, close the game, and reopen it a second time while holding R to access HBMenu**.

To stop the controller later, run **stop-gui.bat** (Windows), **stop-gui.command** (macOS) or **./stop-gui.sh** (Linux); closing the browser tab does not stop it. It stops the controller, any run it started, the bridge and the console loop.

If a run fails, the controller does the **Attempt failed** cleanup automatically:
it stops the run and the bridge and marks the boot used. Relaunch Seedsow, press
**Y**, then press **Start**. The **Attempt failed** button does the same by hand.
A power cycle is only needed when the console itself stops responding.

**Restart Game** does the same but also walks through the console's menus, which
is handy when the console is on an unexpected screen.

### Controller panel

The controller panel sends button presses (A, B, X, Y, D-pad, sticks, HOME,
CAPTURE, …), runs saved button sequences and has **Release all** to drop queued
presses.

## Command line

The same run can be started without the browser:

```
node ns2-run.cjs
```

Options: `--ip <address>` to save the console address to `tools/console-host.txt`
before the run, `--dir <kaiHEN folder>` to use a different kaiHEN release,
`--update-kaihen <folder>` to replace the one in `kaihen/`, `--no-setup` to skip
the console setup step, `--probe` to stop after the RO replacement.

## Configuration

`env.txt` holds the run configuration and is already set to the working values.
A machine can override any of them in `env.local.txt` (create it next to
`env.txt`; it is read second and wins). Addresses and tokens do not go in either
file - they belong in `tools/console-host.txt` and
`controller-connection.json`.

### Offline boot (no second machine)

For a boot that needs no LAN after the card is copied by hand, put
`console/n2h_rpc.lua`, `console/n2h_pump.lua` and `console/offline.lua` in the
save data, the kaiHEN release in `kaihen/` and the tuning keys in
`sd:/n2h/env.txt` on the SD card. The launcher loads the two lua files and
`offline.lua` runs the four stages on the console alone: map check, FS
acquisition (alias buckets from `env.txt`), heap/LOADER check, then the kaiHEN
bootstrap through `ldr:ro`. Only the one-time file copy needs a computer; the
TCP RPC loop is still there for a host that wants it, just never required.

## Writing a controller

Any controller - Pico W, ESP32, a PC applet, a phone - can drive this, because
the controller is just a small HTTP API: `status`, `press`, `release`, `tap`,
`sequence` and `stop`, with an optional bearer token. No changes to this
repository are needed.

See **[CONTROLLER.md](CONTROLLER.md)** for the calls, the button names, the
timing rules and a complete example bridge.

---

## Credits

- [alula/switch-artemis-launcher](https://github.com/alula/switch-artemis-launcher) - the Seedsow launcher save this runs on
- [kurumuz](https://github.com/kurumuz) - kaiHEN, ns2jb fork
- [manupear](https://github.com/manupear) - contributing to this projects development
- [McGlowSticks](https://github.com/McGlowSticks) - contributing to the development of this project
- [aveao](https://github.com/aveao) - contributing to the development of this project
- [TheCrazy8](https://github.com/TheCrazy8) - Testing on the full version of the game
- LLM's were used in the development on this project
