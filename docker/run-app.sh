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
  # There is no gnome-keyring/kwallet in the container, so Electron's
  # safeStorage would report encryption unavailable — and the integrations
  # secret broker refuses to write a secret it can't encrypt. `basic` gives it
  # Chromium's built-in key: secrets stay encrypted at rest in the volume, but
  # the key is not protected by an OS keyring. See README's Docker section.
  --password-store=basic
)

# Extra switches without editing this file, e.g. ELECTRON_EXTRA_ARGS=--disable-gpu.
if [ -n "${ELECTRON_EXTRA_ARGS:-}" ]; then
  # Word splitting is the point here.
  # shellcheck disable=SC2206
  args+=(${ELECTRON_EXTRA_ARGS})
fi

# dbus-run-session gives Electron a session bus, which desktop notifications and
# the secret/portal lookups expect; without it the app logs bus errors on boot.
exec dbus-run-session -- "${APP_DIR}/node_modules/.bin/electron" "${APP_DIR}" "${args[@]}"
