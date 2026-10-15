<p align="center">
  <img src="assets/app-icon.svg" width="128" height="128" alt="Clawd Tank App Icon">
</p>

<h1 align="center">Clawd Tank</h1>

A tiny desktop aquarium for your Claude Code sessions.

Clawd Tank is a notification display for Claude Code built on a [Waveshare ESP32-C6-LCD-1.47](https://s.click.aliexpress.com/e/_c4PGS55v) (320x172 ST7789). An animated pixel-art crab named Clawd lives on the screen, reacting to your coding session — alerting on new notifications, celebrating when you dismiss them, and sleeping when you're away.

**No hardware? No problem.** On Linux the simulator runs as a small borderless desktop window driven by your Claude Code sessions, and `./linux/install.sh` builds and sets everything up (see [Quick Start](#quick-start)). This repository is a Linux port of [marciogranzotto/clawd-tank](https://github.com/marciogranzotto/clawd-tank), which is macOS-first; the macOS instructions are kept [further down](#macos).

<p align="center">
  <img src="assets/sim-recordings/clawd-multi-session.gif" alt="Multi-session display" width="480">
  <img src="assets/sim-recordings/clawd-notification.gif" alt="Clawd notification" width="480">
</p>

## How It Works

```
Claude Code hooks --> clawd-tank-notify --> daemon --> BLE --> ESP32-C6 display
                                                  \-> TCP --> Simulator (SDL2)
```

1. **Claude Code hooks** (`SessionStart`, `PreToolUse`, `PreCompact`, `Stop`, `StopFailure`, `Notification`, `UserPromptSubmit`, `SessionEnd`, `SubagentStart`, `SubagentStop`) fire on session events
2. **clawd-tank-notify** (`~/.clawd-tank/clawd-tank-notify`) forwards the event to the daemon via Unix socket
3. The **daemon** tracks per-session state, maps `tool_name` to animations, and sends JSON payloads to connected transports (BLE hardware, TCP simulator)
4. The **firmware** (or simulator) renders Clawd's tool-aware animation + notification cards on the LCD via LVGL

## Components

| Directory | What | Language |
|-----------|------|----------|
| `firmware/` | ESP-IDF firmware (LVGL UI, NimBLE GATT server, SPI display) | C |
| `simulator/` | Native simulator (Linux, macOS) — runs the same firmware code without hardware | C |
| `host/` | Background daemon, Claude Code hook handler, macOS menu bar app (macOS only) | Python |
| `linux/` | Linux installer (`install.sh`) and Hyprland window rules | Bash |
| `tools/` | Sprite pipeline (SVG to PNG to RLE-compressed RGB565), GIF recorder, BLE debugging | Python |

## Hardware

- **Board**: [Waveshare ESP32-C6-LCD-1.47](https://s.click.aliexpress.com/e/_c4PGS55v)
- **Display**: 1.47" 320x172 ST7789V (SPI), 16-bit RGB565
- **SoC**: ESP32-C6FH8 (RISC-V, single core), 8MB flash, 512KB SRAM (no PSRAM)
- **RGB LED**: Onboard WS2812B on GPIO8 — flashes on incoming notifications
- **Connectivity**: BLE 5.0 (NimBLE, peripheral role)

## Quick Start

### Linux (Arch / Omarchy)

This is the recommended way to run Clawd Tank on Linux. There is no menu bar app here; the installer compiles the simulator, registers the Claude Code hooks, and runs the simulator window and the daemon as systemd user services:

```bash
git clone https://github.com/VloStudios/clawd-tank-linux.git
cd clawd-tank-linux
./linux/install.sh
```

Then restart any running Claude Code sessions. On Hyprland, copy the float/pin rules from [`linux/hyprland-rules.conf`](linux/hyprland-rules.conf) into your config, since the borderless window would otherwise be tiled. `./linux/install.sh uninstall` removes everything it added.

**Logs (systemd journal).** On Linux the daemon and simulator log to the journal rather than to a file:

```bash
journalctl --user -u clawd-tank-daemon -f      # follow the daemon (hook events, transport state)
journalctl --user -u clawd-tank-sim -f         # follow the simulator window process
journalctl --user -u clawd-tank-daemon -u clawd-tank-sim --since "10 min ago"
systemctl --user status clawd-tank-sim clawd-tank-daemon
```

Step-by-step compile instructions, manual service setup, and troubleshooting are in [docs/linux.md](docs/linux.md). The simulator compile and the hook → daemon → simulator pipeline were verified in a headless Linux container; a real Wayland/Hyprland session has not been tested yet.

### Build the simulator by hand

`./linux/install.sh` does all of this for you. To do it manually (full walkthrough in [docs/linux.md](docs/linux.md)):

```bash
# Arch / Omarchy build dependencies
sudo pacman -S --needed base-devel cmake git python sdl2

# LVGL is an ESP-IDF managed component, so it is not stored in git. Fetch the pinned revision once:
mkdir -p firmware/managed_components/lvgl__lvgl
git -C firmware/managed_components/lvgl__lvgl init -q
git -C firmware/managed_components/lvgl__lvgl fetch --depth 1 https://github.com/lvgl/lvgl.git 85aa60d18b3d5e5588d7b247abf90198f07c8a63
git -C firmware/managed_components/lvgl__lvgl checkout FETCH_HEAD

cd simulator
cmake -B build && cmake --build build -j"$(nproc)"

# Interactive mode — opens a borderless, resizable SDL2 window
./build/clawd-tank-sim

# Interactive + TCP listener — daemon can connect and drive it
./build/clawd-tank-sim --listen

# Self-contained binary (no system SDL2 needed; audio is disabled because SDL 2.30's PipeWire backend does not build on Arch)
cmake -B build-static -DSTATIC_SDL2=ON -DSDL_AUDIO=OFF -DSDL_PIPEWIRE=OFF && cmake --build build-static -j"$(nproc)"

# Headless mode — outputs PNG screenshots
./build/clawd-tank-sim --headless \
  --events 'connect; wait 500; notify "clawd-tank" "Waiting for input"; wait 2000; disconnect' \
  --screenshot-dir ./shots/ --screenshot-on-event
```

Interactive keys: `c` connect, `d` disconnect, `n` add notification, `1-8` dismiss, `x` clear, `s` screenshot, `z` sleep, `q` quit. The window is borderless and resizable — drag from center, resize from edges.

When `--listen` is active (default port 19872), the daemon can connect over TCP and drive the simulator with the same JSON protocol used over BLE, enabling the full Claude Code → daemon → display pipeline without hardware.

See [simulator/README.md](simulator/README.md) for full CLI reference and JSON scenario support.

### Host Daemon (standalone)

`./linux/install.sh` runs the daemon as a systemd user service. To run it by hand, start the simulator with a TCP listener, then the daemon. Simulator-only mode needs nothing beyond the Python standard library:

```bash
# Terminal 1 — simulator window with TCP listener
./simulator/build/clawd-tank-sim --listen

# Terminal 2 — daemon, simulator only (no BLE)
cd host && PYTHONPATH=. python3 -m clawd_tank_daemon.daemon --sim-only

# With the real ESP32 board as well (BLE via bleak/BlueZ; untested on Linux):
#   sudo pacman -S python-bleak bluez
cd host && PYTHONPATH=. python3 -m clawd_tank_daemon.daemon --sim
```

The hook script installed by `./linux/install.sh` (`~/.clawd-tank/clawd-tank-notify`) does not start the daemon itself, so keep it running, ideally via the systemd service. Under systemd, logs are in the journal (`journalctl --user -u clawd-tank-daemon -f`); run by hand, they go to your terminal.

### Firmware

Requires [ESP-IDF 5.3.2](https://docs.espressif.com/projects/esp-idf/en/v5.3.2/esp32c6/get-started/index.html) (bundled in `bsp/esp-idf/`, activated via direnv).

```bash
cd firmware
idf.py build
idf.py -p /dev/ttyACM0 flash monitor
```

## macOS

The sections below are the upstream macOS instructions, kept for reference. They are not needed on Linux. The release download points at the upstream project's [Releases](https://github.com/marciogranzotto/clawd-tank/releases) page. To build the simulator from source on macOS, run `brew install sdl2 cmake` and then follow the same CMake steps as above.

### Download the app (no hardware needed)

Grab the latest `.app` from [Releases](https://github.com/marciogranzotto/clawd-tank/releases), unzip, and drag to Applications. The app bundles the simulator — a borderless, resizable window shows Clawd on your desktop, driven by your Claude Code sessions.

On first launch: click the crab icon in the menu bar → **Install Claude Code Hooks**. Restart any running Claude Code sessions.

### macOS Menu Bar App

The menu bar app bundles the daemon and simulator with a status bar UI. It manages two independent transports — **BLE** (hardware) and **Simulator** (software) — each with their own submenu for enable/disable and connection status.

```bash
# Run from source
cd host && python -m clawd_tank_menubar

# Build and install (builds static simulator, py2app, bundles binary)
cd host && ./build.sh --install

# Or build manually
cd host && pip install py2app && python setup.py py2app
cp ../simulator/build-static/clawd-tank-sim "dist/Clawd Tank.app/Contents/MacOS/"
open "dist/Clawd Tank.app"
```

**Menu features:**
- BLE and Simulator transport submenus with enable/disable toggles
- Simulator window controls: Show/Hide, Always on Top
- Brightness slider, session timeout picker
- Claude Code hook installer
- Version display (tag or branch+N@sha)
- Launch at Login with stale plist detection

On launch, the app automatically installs a hook handler script to `~/.clawd-tank/clawd-tank-notify`. To connect it to Claude Code, click **"Install Claude Code Hooks"** in the menu bar dropdown — this adds the required hooks to `~/.claude/settings.json`. Restart any running Claude Code sessions for hooks to take effect.

Logs are written to `~/Library/Logs/ClawdTank/clawd-tank.log`.

Pre-built releases are available on the [Releases](https://github.com/marciogranzotto/clawd-tank/releases) page.

## Features

- **Multi-session display** — up to 4 concurrent Claude Code sessions shown as individual animated Clawd sprites, each with their own working animation. New sessions walk in, exiting sessions burrow away
- **Tool-aware animations** — Clawd shows distinct animations based on which tool Claude is using: debugger (Read/Grep), typing (Edit/Write), building (Bash), wizard (WebSearch), conducting (Agent/subagents), beacon (LSP/MCP)
- **Session tracking** — daemon tracks per-session state with priority-based display resolution, staleness eviction, and subagent lifecycle tracking
- **Session persistence** — session state survives daemon restarts, so relaunching the app immediately shows the correct animation for running sessions
- **Time display** — synced from host over BLE on connect (no WiFi/NTP needed)
- **RGB LED flash** — onboard WS2812B cycles through colors on new notifications
- **RLE sprite compression** — all sprite assets compressed ~14:1 (13MB raw → ~900KB)
- **Simulator** — runs natively on Linux (and bundled in the macOS `.app`), no hardware needed. Borderless resizable window with integer pixel scaling
- **Multi-transport** — daemon supports BLE (hardware) and TCP (simulator) transports simultaneously, independently enable/disable
- **Simulator bridge** — full pipeline works without hardware via `--listen` flag and TCP. Window show/hide/pinned controlled over TCP
- **Static SDL2 build** — `STATIC_SDL2=ON` produces a self-contained binary with zero external dependencies
- **Auto-reconnect** — daemon replays active notifications and display state after reconnect on any transport
- **Config over BLE/TCP** — brightness and session timeout adjustable via config characteristic or TCP
- **Linux support** — one-command installer, systemd user services, Hyprland window rules, journal logging
- **macOS menu bar app** (macOS only) — transport submenus with colored status indicators, simulator window controls, brightness slider, session timeout, hook installer, version display, launch-at-login

## Clawd's Moods

### Tool-Aware Animations

Clawd's animation reflects which tool Claude is currently using. Each session gets its own Clawd sprite with a tool-specific animation:

| Animation | Tools | |
|-----------|-------|---|
| **Debugger** | `Read`, `Grep`, `Glob` — searching/inspecting code | ![Debugger](assets/sim-recordings/clawd-debugger.gif) |
| **Typing** | `Edit`, `Write`, `NotebookEdit` — writing code | ![Typing](assets/sim-recordings/clawd-typing.gif) |
| **Building** | `Bash` — running shell commands | ![Building](assets/sim-recordings/clawd-building.gif) |
| **Conducting** | `Agent` / active subagents — orchestrating work | ![Conducting](assets/sim-recordings/clawd-conducting.gif) |
| **Wizard** | `WebSearch`, `WebFetch` — conjuring web knowledge | ![Wizard](assets/sim-recordings/clawd-wizard.gif) |
| **Beacon** | `LSP`, MCP tools (`mcp__*`) — communicating with services | ![Beacon](assets/sim-recordings/clawd-beacon.gif) |

### Session States

| State | When | |
|-------|------|---|
| **Multi-session** | 2+ concurrent sessions, each with individual tool animations | ![Multi-session](assets/sim-recordings/clawd-multi-session.gif) |
| **Thinking** | User submitted a prompt, Claude is reasoning | ![Thinking](assets/sim-recordings/clawd-thinking.gif) |
| **Confused** | Claude has been waiting 60s+ for user input | ![Confused](assets/sim-recordings/clawd-confused.gif) |
| **Sweeping** | Context compaction (PreCompact) — oneshot | ![Sweeping](assets/sim-recordings/clawd-sweeping.gif) |

### HUD Badges

| Badge | When | |
|-------|------|---|
| **Subagent counter** | Active subagents — mini-crab icon with `×N` count (top-left) | ![Subagents](assets/sim-recordings/clawd-hud-subagents.gif) |
| **Overflow (wide)** | 5+ sessions — `+N` badge shows extra sessions beyond the 4 visible (top-right) | ![Overflow wide](assets/sim-recordings/clawd-overflow-wide.gif) |
| **Overflow (narrow)** | Notification panel open — `×N` badge shows total session count (top-right of scene) | ![Overflow narrow](assets/sim-recordings/clawd-overflow-narrow.gif) |

### Notification & Lifecycle

| State | When | |
|-------|------|---|
| **Idle** | Connected, no notifications — Clawd hangs out, full-screen with clock | ![Idle](assets/sim-recordings/clawd-idle.gif) |
| **Alert** | New notification arrives — Clawd shifts left, cards appear, LED flashes | ![Alert](assets/sim-recordings/clawd-notification.gif) |
| **Happy** | Notifications dismissed | ![Happy](assets/sim-recordings/clawd-happy.gif) |
| **Sleeping** | No active sessions — all sessions ended or evicted | ![Sleeping](assets/sim-recordings/clawd-sleeping.gif) |
| **Disconnected** | No BLE connection — "No connection" message | ![Disconnected](assets/sim-recordings/clawd-disconnected.gif) |

## Tests

```bash
# C unit tests (notification store)
cd firmware/test && make test

# Python tests (host daemon + protocol)
cd host && pip install -r requirements-dev.txt && pytest
```

On Linux the Python test suite has not been run yet, and `rumps` in `requirements.txt` is macOS-only. See [TODO.md](TODO.md).

## Sprite Pipeline

Clawd's animations are pixel art generated as animated SVGs, rendered to PNG frame sequences, and converted to RLE-compressed RGB565 C headers:

```bash
# SVG animation → PNG frames (requires Playwright)
python tools/svg2frames.py assets/svg-animations/clawd-working-thinking.svg /tmp/frames/ \
  --fps 8 --duration auto --scale 4

# PNG frames → C header
python tools/png2rgb565.py /tmp/frames/ firmware/main/assets/sprite_thinking.h --name thinking

# Record seamlessly-looping GIFs of all animations (for docs)
python tools/record_gif.py --all assets/captures/
```

## BLE Debugging

```bash
# Interactive BLE tool — connect, send notifications, read config
python tools/ble_interactive.py
```

## License

MIT
