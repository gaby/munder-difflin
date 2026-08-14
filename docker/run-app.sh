#!/usr/bin/env bash
#
# Launch the compiled app (out/main/index.js, per package.json "main") on the
# display entrypoint.sh set up.
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/munder-difflin}"

args=(
  # Chromium's setuid sandbox needs privileges the container doesn't have.
  --no-sandbox
  --disable-gpu-sandbox
  # Docker's default /dev/shm is 64MB; Chromium crashes on it. compose raises
  # shm_size, this keeps a plain `docker run` working too.
  --disable-dev-shm-usage
  # No GPU here — the Pixi.js office floor renders through SwiftShader.
  --enable-unsafe-swiftshader
)

# NOT passed here: --password-store=basic. It would make no difference anyway.
#
# Measured on this Electron (32) with no keyring present, via
# safeStorage.isEncryptionAvailable() / getSelectedStorageBackend():
#
#   no flag                        -> basic_text,      available = false
#   --password-store=basic         -> basic_text,      available = false
#   --password-store=gnome-libsecret -> gnome_libsecret, available = false
#
# So integrations.ts:setSecret ("never writes plaintext") fails closed here in
# every configuration — Electron reports the basic_text fallback as unavailable
# rather than handing out its hardcoded key. In-app secret storage simply does
# not work in this container, and no flag turns it on; only a real unlocked
# keyring daemon would, which this image does not ship. Keys come from the
# environment instead (compose passes the provider variables through).

# Extra switches without editing this file, e.g. ELECTRON_EXTRA_ARGS=--disable-gpu.
if [ -n "${ELECTRON_EXTRA_ARGS:-}" ]; then
  # Word splitting is the point here.
  # shellcheck disable=SC2206
  args+=(${ELECTRON_EXTRA_ARGS})
fi

# Electron needs a session bus (desktop notifications, portal lookups; without
# one it logs bus errors on boot) — but it must NOT be started under
# `dbus-run-session`, which is the obvious way to get one.
#
# That wrapper does not forward signals: send it SIGTERM and it exits, leaving
# the app orphaned to be SIGKILLed when the grace period runs out. `docker
# compose stop` would then skip Electron's before-quit/will-quit entirely and
# tear down live agents mid-flight. Verified directly: SIGTERM to a
# `dbus-run-session -- sleep` leaves the sleep running.
#
# So start the bus beside the app and export its address, and let Electron be
# the process this script execs — it then receives SIGTERM itself and shuts down
# cleanly. The daemon is left to die with the container.
if command -v dbus-launch >/dev/null 2>&1; then
  eval "$(dbus-launch --sh-syntax)"
  export DBUS_SESSION_BUS_ADDRESS
fi

# dunst has to be on that same bus, and started before Electron: a notification
# only appears if something owns org.freedesktop.Notifications. libnotify alone
# is just the client side — without a daemon, Notification.isSupported() still
# reports true and the breaker's toasts go nowhere.
if command -v dunst >/dev/null 2>&1; then
  dunst &
fi

exec "${APP_DIR}/node_modules/.bin/electron" "${APP_DIR}" "${args[@]}"
