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

# NOT passed here: --password-store=basic.
#
# There is no gnome-keyring/kwallet in the container, so safeStorage reports
# encryption unavailable and integrations.ts:setSecret refuses to write —
# "never writes plaintext" is a deliberate fail-closed contract. Passing
# `basic` would satisfy isEncryptionAvailable() with Chromium's hardcoded key,
# which is obfuscation, not encryption: it would turn that contract fail-OPEN
# and land near-plaintext credentials in integration-secrets.json while the app
# believed they were protected.
#
# So the container behaves exactly as the app does on any Linux box with no
# keyring: in-app secret storage is unavailable, and keys come from the
# environment instead (compose passes ANTHROPIC_API_KEY / OPENAI_API_KEY
# through). To accept the weaker protection and re-enable in-app storage, opt
# in explicitly:  ELECTRON_EXTRA_ARGS=--password-store=basic

# Extra switches without editing this file, e.g. ELECTRON_EXTRA_ARGS=--disable-gpu.
if [ -n "${ELECTRON_EXTRA_ARGS:-}" ]; then
  # Word splitting is the point here.
  # shellcheck disable=SC2206
  args+=(${ELECTRON_EXTRA_ARGS})
fi

# dbus-run-session gives Electron a session bus, which desktop notifications and
# the secret/portal lookups expect; without it the app logs bus errors on boot.
#
# dunst starts INSIDE that session, before Electron: a notification only shows up
# if something owns org.freedesktop.Notifications on the same bus. libnotify
# alone is just the client side — without a daemon, Notification.isSupported()
# still reports true and the breaker's toasts go nowhere.
exec dbus-run-session -- bash -c '
  if command -v dunst >/dev/null 2>&1; then dunst & fi
  exec "$@"
' md-run-app "${APP_DIR}/node_modules/.bin/electron" "${APP_DIR}" "${args[@]}"
