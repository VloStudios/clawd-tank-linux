#!/usr/bin/env bash
# linux/install.sh — build and install Clawd Tank on Linux (tested target: Arch / Omarchy, Hyprland).
#
# Builds the desktop simulator (no ESP32 board needed), registers the Claude Code
# hooks, and runs the simulator window + daemon as systemd user services.
#
#   ./linux/install.sh              install or update (re-run after `git pull`)
#   ./linux/install.sh uninstall    remove services, binary, hooks and ~/.clawd-tank
#
# Environment:
#   CLAWD_SCALE=2          simulator window scale (1 = 320x172 px, 2 = 640x344 px)
#   CLAWD_STATIC_SDL=1     build against upstream's bundled static SDL2 instead of the system one
#
# The services run straight from this checkout, so keep it where it is (or re-run
# this script after moving it).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LVGL_URL="https://github.com/lvgl/lvgl.git"
LVGL_REV="85aa60d18b3d5e5588d7b247abf90198f07c8a63"   # same pin as .github/workflows/release.yml
LVGL_DIR="$REPO_DIR/firmware/managed_components/lvgl__lvgl"

SCALE="${CLAWD_SCALE:-2}"
STATIC_SDL="${CLAWD_STATIC_SDL:-0}"

BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"
SETTINGS="$HOME/.claude/settings.json"
PYTHON="$(command -v python3 || true)"

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

install_deps() {
  local need=0 c
  for c in git cmake gcc make python3 pkg-config; do
    command -v "$c" >/dev/null 2>&1 || need=1
  done
  if [ "$STATIC_SDL" != 1 ]; then
    pkg-config --exists sdl2 2>/dev/null || need=1
  fi
  [ "$need" = 0 ] && return 0

  if command -v pacman >/dev/null 2>&1; then
    say "Installing build dependencies (sudo will ask for your password)"
    sudo pacman -S --needed base-devel cmake git python sdl2
  else
    die "missing build dependencies. Install git, cmake, a C compiler, make, python3, pkg-config and the SDL2 development files with your package manager (or set CLAWD_STATIC_SDL=1 to bundle SDL2), then re-run."
  fi
  PYTHON="$(command -v python3)"
}

fetch_lvgl() {
  # LVGL is an ESP-IDF managed component, so it is not in git. Fetch the pinned revision.
  if [ -d "$LVGL_DIR/.git" ] && [ "$(git -C "$LVGL_DIR" rev-parse HEAD 2>/dev/null)" = "$LVGL_REV" ]; then
    return 0
  fi
  say "Fetching LVGL ($LVGL_REV)"
  mkdir -p "$LVGL_DIR"
  [ -d "$LVGL_DIR/.git" ] || { git -C "$LVGL_DIR" init -q; git -C "$LVGL_DIR" remote add origin "$LVGL_URL"; }
  git -C "$LVGL_DIR" fetch -q --depth 1 origin "$LVGL_REV"
  git -C "$LVGL_DIR" -c advice.detachedHead=false checkout -q --force FETCH_HEAD
}

build_static_sdl() {
  # The simulator only initialises SDL's video subsystem, so build the bundled SDL2 without audio.
  # SDL 2.30's PipeWire audio backend fails to compile against current PipeWire headers (Arch).
  cmake -B build-static -DSTATIC_SDL2=ON -DSDL_AUDIO=OFF -DSDL_PIPEWIRE=OFF \
    && cmake --build build-static -j"$(nproc)"
}

build_simulator() {
  say "Compiling the simulator"
  cd "$REPO_DIR/simulator"
  local out
  if [ "$STATIC_SDL" = 1 ]; then
    build_static_sdl
    out=build-static/clawd-tank-sim
  elif cmake -B build && cmake --build build -j"$(nproc)"; then
    out=build/clawd-tank-sim
  else
    say "System SDL2 build failed (errors above); retrying with the bundled static SDL2"
    build_static_sdl
    out=build-static/clawd-tank-sim
  fi
  install -Dm755 "$out" "$BIN_DIR/clawd-tank-sim"
}

install_hooks() {
  say "Installing the Claude Code hook script and hooks"
  if [ -f "$SETTINGS" ]; then
    "$PYTHON" -c 'import json,sys; json.load(open(sys.argv[1]))' "$SETTINGS" 2>/dev/null \
      || die "$SETTINGS is not valid JSON; fix it first (nothing was changed)"
    cp -p "$SETTINGS" "$SETTINGS.bak-clawd-tank-$(date +%Y%m%d%H%M%S)"
  fi
  # Same installer the macOS menu bar app uses: writes ~/.clawd-tank/clawd-tank-notify and
  # merges the hooks into ~/.claude/settings.json without touching your own hooks.
  PYTHONPATH="$REPO_DIR/host" "$PYTHON" - <<'PY'
from clawd_tank_menubar import hooks
hooks.install_notify_script()
hooks.install_hooks()
PY
}

install_services() {
  say "Installing systemd user services"
  mkdir -p "$UNIT_DIR"
  cat > "$UNIT_DIR/clawd-tank-sim.service" <<EOF
[Unit]
Description=Clawd Tank simulator window
After=graphical-session.target
PartOf=graphical-session.target
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
ExecStart=$BIN_DIR/clawd-tank-sim --listen --scale $SCALE
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
EOF
  cat > "$UNIT_DIR/clawd-tank-daemon.service" <<EOF
[Unit]
Description=Clawd Tank daemon (Claude Code hooks to simulator)
After=clawd-tank-sim.service

[Service]
WorkingDirectory=$REPO_DIR/host
Environment=PYTHONPATH=$REPO_DIR/host
Environment=PYTHONUNBUFFERED=1
ExecStart=$PYTHON -m clawd_tank_daemon.daemon --sim-only
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable clawd-tank-daemon.service clawd-tank-sim.service
  systemctl --user restart clawd-tank-daemon.service clawd-tank-sim.service

  if ! systemctl --user show-environment | grep -q '^WAYLAND_DISPLAY=\|^DISPLAY='; then
    printf '\nwarning: the systemd user session has no WAYLAND_DISPLAY/DISPLAY, so the window may not open.\n'
    printf '         Try: systemctl --user import-environment WAYLAND_DISPLAY DISPLAY && systemctl --user restart clawd-tank-sim\n'
  fi
}

print_next_steps() {
  cat <<EOF

Done.

1. Restart any running Claude Code sessions (hooks are read at session start).
2. Wayland compositors (Hyprland/Omarchy) tile new windows. Make the borderless window float:
   see $REPO_DIR/linux/hyprland-rules.conf
3. Logs:   journalctl --user -u clawd-tank-daemon -f
   Status: systemctl --user status clawd-tank-sim clawd-tank-daemon
EOF
}

uninstall() {
  say "Removing Clawd Tank"
  systemctl --user disable --now clawd-tank-sim.service clawd-tank-daemon.service 2>/dev/null || true
  rm -f "$UNIT_DIR/clawd-tank-sim.service" "$UNIT_DIR/clawd-tank-daemon.service"
  systemctl --user daemon-reload 2>/dev/null || true

  if [ -f "$SETTINGS" ] && [ -n "$PYTHON" ]; then
    cp -p "$SETTINGS" "$SETTINGS.bak-clawd-tank-$(date +%Y%m%d%H%M%S)"
    PYTHONPATH="$REPO_DIR/host" "$PYTHON" - <<'PY'
import json
from clawd_tank_menubar import hooks
p = hooks.CLAUDE_SETTINGS_PATH
s = json.loads(p.read_text())
h = s.get("hooks", {})
for ev in list(h):
    if isinstance(h[ev], list):
        h[ev] = [g for g in h[ev] if not hooks._is_our_managed_group(g)]
        if not h[ev]:
            del h[ev]
if not h:
    s.pop("hooks", None)
p.write_text(json.dumps(s, indent=2) + "\n")
PY
  else
    echo "note: could not remove the hooks automatically; delete the Clawd Tank entries from $SETTINGS by hand"
  fi
  rm -f "$BIN_DIR/clawd-tank-sim"
  rm -rf "$HOME/.clawd-tank"
  echo "Removed. Backups of settings.json (settings.json.bak-clawd-tank-*) were left in place."
}

case "${1:-install}" in
  install)
    install_deps
    fetch_lvgl
    build_simulator
    install_hooks
    install_services
    print_next_steps
    ;;
  uninstall) uninstall ;;
  *) die "usage: $0 [install|uninstall]" ;;
esac
