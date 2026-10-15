# Clawd Tank on Linux (Arch / Omarchy)

Clawd Tank was written macOS-first: the supported desktop experience upstream is a menu bar
app that bundles the simulator. On Linux there is no menu bar app. Instead you compile the
**simulator** (the window with the crab in it, standing in for the ESP32 display), run the
**daemon** that feeds it, and register the **Claude Code hooks**. The installer in
`linux/install.sh` does all of that and runs the two long-lived pieces as systemd user services.

```
Claude Code hooks -> ~/.clawd-tank/clawd-tank-notify -> daemon --sim-only -> TCP :19872 -> clawd-tank-sim (SDL2 window)
```

> **Status.** The simulator compile and the whole hook -> daemon -> simulator pipeline were
> verified in a headless Linux container. Opening a real window on Wayland/Hyprland, the
> systemd services on a live Omarchy session, and non-Arch distros have **not** been tested yet.

## What "compiling" means here

The simulator is written in C. The repository holds source code only, so you turn it into a
runnable program (`clawd-tank-sim`) with a compiler. It also needs two libraries: **SDL2**
(opens the window) and **LVGL** (draws the UI; it is fetched for you, pinned to the version
upstream uses). The first build takes a minute or two.

## Quick start (one command)

```bash
git clone https://github.com/VloStudios/clawd-tank-linux.git
cd clawd-tank-linux
./linux/install.sh
```

It will ask for your sudo password once (pacman installs the build dependencies), then compile
the simulator, install the hooks, and start the services. Afterwards:

1. **Restart any running Claude Code sessions.** Hooks are read when a session starts.
2. **Float the window.** The window is borderless, so Hyprland tiles it by default. Copy the
   rules from [`linux/hyprland-rules.conf`](../linux/hyprland-rules.conf) into a file your
   `hyprland.conf` sources (in Omarchy that is `~/.config/hypr/`), then `hyprctl reload`.

Options: `CLAWD_SCALE=1|2|3` sets the window size (default 2 = 640x344 px) and
`CLAWD_STATIC_SDL=1` builds against upstream's bundled static SDL2 instead of the system one.
Re-run the script after `git pull` to update. `./linux/install.sh uninstall` removes
everything it added.

## Compiling by hand

### 1. Dependencies

| Distro | Command |
| --- | --- |
| Arch / Omarchy | `sudo pacman -S --needed base-devel cmake git python sdl2` |
| Debian / Ubuntu *(untested)* | `sudo apt install build-essential cmake git python3 pkg-config libsdl2-dev` |
| Fedora *(untested)* | `sudo dnf install gcc make cmake git python3 pkgconf-pkg-config SDL2-devel` |

Python 3.9+ is enough for the daemon; it uses only the standard library in `--sim-only` mode.

### 2. Get the source and LVGL

```bash
git clone https://github.com/VloStudios/clawd-tank-linux.git
cd clawd-tank-linux

# LVGL is an ESP-IDF "managed component" and is not stored in git. Fetch the pinned revision:
mkdir -p firmware/managed_components/lvgl__lvgl
cd firmware/managed_components/lvgl__lvgl
git init -q && git remote add origin https://github.com/lvgl/lvgl.git
git fetch --depth 1 origin 85aa60d18b3d5e5588d7b247abf90198f07c8a63
git checkout FETCH_HEAD
cd ../../..
```

### 3. Build

```bash
cd simulator
cmake -B build
cmake --build build -j"$(nproc)"
```

If CMake cannot find SDL2, build with the bundled static copy instead (downloads SDL2 from GitHub):

```bash
cmake -B build-static -DSTATIC_SDL2=ON
cmake --build build-static -j"$(nproc)"
```

The result is `simulator/build/clawd-tank-sim` (or `build-static/`). Put it on your PATH:

```bash
install -Dm755 build/clawd-tank-sim ~/.local/bin/clawd-tank-sim
```

### 4. Try it without hooks

Headless, no window, writes PNG screenshots:

```bash
clawd-tank-sim --headless \
  --events 'connect; wait 500; notify "clawd-tank" "Waiting for input"; wait 2000; disconnect' \
  --screenshot-dir ./shots/ --screenshot-on-event
```

With a window (keys: `n` notify, `x` clear, `z` sleep, `q` quit):

```bash
clawd-tank-sim --scale 2
```

### 5. Install the Claude Code hooks

From the repository root. This writes `~/.clawd-tank/clawd-tank-notify` and merges the hooks into
`~/.claude/settings.json` without touching your own hooks. It is the same code the macOS app
runs, and it is safe to run repeatedly. Back up `settings.json` first if you care about it.

```bash
cp ~/.claude/settings.json ~/.claude/settings.json.bak   # if the file exists
PYTHONPATH=host python3 -c 'from clawd_tank_menubar import hooks; hooks.install_notify_script(); hooks.install_hooks()'
```

### 6. Run the daemon and simulator

Quick foreground test, in two terminals:

```bash
clawd-tank-sim --listen --scale 2
```
```bash
cd host && PYTHONPATH=. python3 -m clawd_tank_daemon.daemon --sim-only
```

Start a new Claude Code session; Clawd should react. (Use `-m clawd_tank_daemon.daemon`, not
`-m clawd_tank_daemon`: the package has no `__main__.py`.)

### 7. Start both automatically (systemd user services)

Create `~/.config/systemd/user/clawd-tank-sim.service`:

```ini
[Unit]
Description=Clawd Tank simulator window
After=graphical-session.target
PartOf=graphical-session.target
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
ExecStart=%h/.local/bin/clawd-tank-sim --listen --scale 2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
```

and `~/.config/systemd/user/clawd-tank-daemon.service` (replace `/path/to/clawd-tank-linux`):

```ini
[Unit]
Description=Clawd Tank daemon (Claude Code hooks to simulator)
After=clawd-tank-sim.service

[Service]
WorkingDirectory=/path/to/clawd-tank-linux/host
Environment=PYTHONPATH=/path/to/clawd-tank-linux/host
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/python3 -m clawd_tank_daemon.daemon --sim-only
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now clawd-tank-daemon.service clawd-tank-sim.service
```

## Hyprland / Omarchy notes

- **Tiling.** Add the float/pin rules from [`linux/hyprland-rules.conf`](../linux/hyprland-rules.conf).
  The window title is `Clawd Tank Simulator`. The syntax changed in Hyprland 0.53, so check
  `hyprctl version`.
- **Always on top.** The simulator's own `--pinned` flag asks SDL for an always-on-top window,
  which Wayland compositors generally ignore. Use the Hyprland `pin` rule instead.
- **No tray menu.** The macOS menu bar app's controls (show/hide, brightness, session timeout) do
  not exist on Linux. Close the window and the simulator keeps running; restart it with
  `systemctl --user restart clawd-tank-sim`.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| No window appears | `journalctl --user -u clawd-tank-sim`. If it says it cannot open a display, run `systemctl --user import-environment WAYLAND_DISPLAY DISPLAY` and restart the service. To force a backend, add `Environment=SDL_VIDEODRIVER=wayland` (or `x11`) to the unit. |
| Window is tiled into your layout | Add the Hyprland rules above. |
| Crab never reacts | Restart Claude Code, then `journalctl --user -u clawd-tank-daemon -f` while you send a prompt. Confirm `~/.claude/settings.json` has a `clawd-tank-notify` hook. |
| `Another clawd-tank daemon is already running` | Only one daemon can run (`~/.clawd-tank/daemon.lock`). Stop the old one: `systemctl --user stop clawd-tank-daemon`. |
| `Port 19872 in use` | Another simulator is running. `clawd-tank-sim --listen 12345` plus `--sim-port 12345` on the daemon uses a different port. |
| CMake: `Could not find SDL2` | Install the SDL2 development package, or use `-DSTATIC_SDL2=ON`. |

## Using the real ESP32 board on Linux (untested)

The daemon also speaks BLE to the hardware. This path has not been tested on Linux: install
`bluez` and `python-bleak` (`sudo pacman -S bluez python-bleak`), then change the daemon's
`ExecStart` to drop `--sim-only` (or use `--sim` to drive the hardware and the window together).
Building and flashing the firmware is covered in the main [README](../README.md#firmware).

## Differences from upstream

- `host/clawd_tank_daemon/daemon.py` imports `bleak` only when BLE is actually used, so
  `--sim-only` needs no third-party Python packages.
- `simulator/sim_ble_parse.c` includes `<time.h>` for `tzset()` (removes a compiler warning on Linux).
- New: `linux/install.sh`, `linux/hyprland-rules.conf`, this guide.
