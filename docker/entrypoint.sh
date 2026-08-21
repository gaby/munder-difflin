#!/usr/bin/env bash
#
# Bring up the virtual desktop the Electron app needs, then hand off to CMD.
#
#   Xvfb       an in-memory X server — the app's only display
#   openbox    a window manager, so the app can be moved/resized/maximized;
#              without one, X maps the window at its default size with no title
#              bar and no way to change either
#   x11vnc     exports that display over VNC (port 5900)
#   websockify serves noVNC's browser client over HTTP (port 6080)
#
# Overriding CMD (e.g. `docker compose run --rm app bash`) still gets a live
# display, so you can poke at the app by hand.
set -euo pipefail

DISPLAY_NUM="${DISPLAY_NUM:-99}"
export DISPLAY=":${DISPLAY_NUM}"
GEOMETRY="${SCREEN_GEOMETRY:-1600x1000x24}"
VNC_PORT="${VNC_PORT:-5900}"
NOVNC_PORT="${NOVNC_PORT:-6080}"

log() { printf '[munder-difflin] %s\n' "$*" >&2; }

# Agents run git inside /workspace, which is usually a bind mount owned by the
# host user — without this git refuses every command as "dubious ownership".
git config --global --add safe.directory '*' >/dev/null 2>&1 || true

# A fresh volume has no git identity and the host's ~/.gitconfig isn't mounted,
# so the first commit an agent (or the hive's single committer) tries fails with
# "Author identity unknown". Seed it from the environment when provided; never
# overwrite an identity the user already set inside the volume.
if [ -n "${GIT_USER_NAME:-}" ] && ! git config --global user.name >/dev/null 2>&1; then
  git config --global user.name "${GIT_USER_NAME}" || true
fi
if [ -n "${GIT_USER_EMAIL:-}" ] && ! git config --global user.email >/dev/null 2>&1; then
  git config --global user.email "${GIT_USER_EMAIL}" || true
fi
if ! git config --global user.email >/dev/null 2>&1; then
  log "no git identity — set GIT_USER_NAME / GIT_USER_EMAIL, or agents' commits will fail"
fi

log "starting Xvfb on ${DISPLAY} (${GEOMETRY})"
Xvfb "${DISPLAY}" -screen 0 "${GEOMETRY}" -nolisten tcp -noreset &

# Wait for the X socket rather than sleeping a fixed amount — a slow first boot
# would otherwise race the app's window creation.
for _ in $(seq 1 100); do
  [ -S "/tmp/.X11-unix/X${DISPLAY_NUM}" ] && break
  sleep 0.1
done
if [ ! -S "/tmp/.X11-unix/X${DISPLAY_NUM}" ]; then
  log "Xvfb failed to start on ${DISPLAY}"
  exit 1
fi

# Our own rc.xml, so openbox neither looks for Debian's menu file nor opens the
# app at a default size inside a larger screen (it maximizes to SCREEN_GEOMETRY).
log "starting openbox"
openbox --config-file "${OPENBOX_CONFIG:-/etc/openbox-rc.xml}" &

vnc_args=(-display "${DISPLAY}" -forever -shared -rfbport "${VNC_PORT}" -noxdamage -quiet)
if [ -n "${VNC_PASSWORD:-}" ]; then
  x11vnc -storepasswd "${VNC_PASSWORD}" "${HOME}/.vncpass" >/dev/null 2>&1
  vnc_args+=(-rfbauth "${HOME}/.vncpass")
  log "VNC password enabled"
else
  # No password. Safe only because compose publishes both ports on 127.0.0.1;
  # set VNC_PASSWORD before exposing this container to a network.
  vnc_args+=(-nopw)
fi

log "starting x11vnc on :${VNC_PORT}"
x11vnc "${vnc_args[@]}" &
vnc_pid=$!

log "starting noVNC on http://localhost:${NOVNC_PORT}"
websockify --web=/usr/share/novnc "${NOVNC_PORT}" "localhost:${VNC_PORT}" &
novnc_pid=$!

# Watchdog. The app doesn't depend on x11vnc/websockify, so if either dies the
# container keeps "running" with Electron happily painting to a display nobody
# can reach — and restart: unless-stopped never fires because nothing exited.
# Take the container down instead and let the restart policy rebuild the stack.
#
# `exec` below preserves this shell's PID, so $$ is the PID the app will have.
# (Xvfb needs no watching: if it dies, Electron loses its display and exits on
# its own. openbox dying only costs window decorations, so it isn't fatal.)
main_pid=$$

# NOT `kill -0`: these helpers stay children of this PID across the exec, and the
# app that replaces this shell never reaps them — so an exited helper lingers as
# a zombie, which `kill -0` reports as perfectly alive. Read the state field out
# of /proc instead (skipping past comm, which can itself contain spaces).
still_running() {
  local pid="$1" state
  [ -d "/proc/${pid}" ] || return 1
  state=$(sed 's/.*) //' "/proc/${pid}/stat" 2>/dev/null | cut -d' ' -f1) || return 1
  [ -n "${state}" ] && [ "${state}" != "Z" ]
}

# WATCHDOG_GRACE seconds between the polite ask and the forced exit.
WATCHDOG_GRACE="${WATCHDOG_GRACE:-10}"

(
  while still_running "${vnc_pid}" && still_running "${novnc_pid}"; do
    sleep 5
  done
  log "x11vnc or noVNC exited — stopping the container so it can restart"
  # SIGTERM first, in case a future build grows a handler for it. Today Electron
  # catches SIGTERM and does nothing with it, and before-quit blocks the quit
  # outright while any PTY is live — waiting on a confirmation dialog in a
  # renderer nobody can reach, because the VNC path is exactly what just died.
  # So TERM alone would leave the container up forever with no way in, and the
  # restart policy would never fire. Escalate.
  kill -TERM "${main_pid}" 2>/dev/null || true
  for _ in $(seq 1 "${WATCHDOG_GRACE}"); do
    still_running "${main_pid}" || exit 0
    sleep 1
  done
  log "still running ${WATCHDOG_GRACE}s after SIGTERM — forcing exit"
  kill -KILL "${main_pid}" 2>/dev/null || true
) &

exec "$@"
