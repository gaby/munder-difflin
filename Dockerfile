# syntax=docker/dockerfile:1

# ─────────────────────────────────────────────────────────────────────────────
#  Munder Difflin in a container.
#
#  This is a *desktop* app (Electron), so there is no headless mode to run: the
#  image ships a virtual X display (Xvfb), a window manager (openbox) and
#  x11vnc/noVNC, and you drive the floor from a browser tab at
#  http://localhost:6080.
#
#  Two stages so the ~1GB of build toolchain (python3/make/g++ for node-pty and
#  better-sqlite3) never lands in the image you actually run.
# ─────────────────────────────────────────────────────────────────────────────

# Node 24 — the Active LTS line (supported to 2028-04-30). Node 20 went EOL on
# 2026-04-30 and gets no more security patches. Stay on `-bookworm-` variants:
# the runtime stage below installs Debian 12 package names.
ARG NODE_VERSION=24

# ── Stage 1: compile ─────────────────────────────────────────────────────────
FROM node:${NODE_VERSION}-bookworm-slim AS builder

# node-gyp needs python3 + a C/C++ toolchain to rebuild node-pty and
# better-sqlite3 against Electron's ABI (the `postinstall` hook runs
# electron-rebuild). git/ca-certificates are for npm's git-backed deps.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      git \
      python3 \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/munder-difflin

# Dependencies first so edits to src/ don't re-run the (slow) native rebuild.
COPY package.json package-lock.json ./
COPY tools/ ./tools/
RUN npm ci

COPY . .

# electron-vite → out/, then copy the plain-JS main-process assets beside it.
RUN npm run build

# ── Stage 2: runtime ─────────────────────────────────────────────────────────
FROM node:${NODE_VERSION}-bookworm-slim AS runtime

# Agent CLIs to bake into the image. Munder Difflin can self-heal a missing CLI
# (it runs the installer in the terminal), but shipping the default provider
# makes a fresh container useful immediately. Build with
# `--build-arg AGENT_CLIS=""` to skip, or pass a space-separated list.
ARG AGENT_CLIS="@anthropic-ai/claude-code"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      # ---- Electron/Chromium shared libraries ----
      libasound2 \
      libatk-bridge2.0-0 \
      libatk1.0-0 \
      libatspi2.0-0 \
      libcairo2 \
      libcups2 \
      libdrm2 \
      libgbm1 \
      libgtk-3-0 \
      libnotify4 \
      libnss3 \
      libpango-1.0-0 \
      libsecret-1-0 \
      libx11-xcb1 \
      libxcomposite1 \
      libxdamage1 \
      libxfixes3 \
      libxkbcommon0 \
      libxrandr2 \
      libxss1 \
      libxtst6 \
      xdg-utils \
      # ---- virtual display + remote access ----
      dbus-x11 \
      novnc \
      openbox \
      websockify \
      x11vnc \
      xvfb \
      # ---- fonts (the UI is pixel art, but terminals still need glyphs) ----
      fonts-liberation \
      fonts-noto-color-emoji \
      # ---- what the agents themselves shell out to ----
      ca-certificates \
      curl \
      git \
      less \
      openssh-client \
      procps \
      ripgrep \
      tzdata \
 && rm -rf /var/lib/apt/lists/*

# Debian's novnc ships vnc.html but no index.html; symlink it so the bare
# http://localhost:6080/ URL lands on the client.
RUN if [ ! -e /usr/share/novnc/index.html ]; then \
      ln -s /usr/share/novnc/vnc.html /usr/share/novnc/index.html; \
    fi

RUN if [ -n "$AGENT_CLIS" ]; then npm install -g $AGENT_CLIS; fi

# The node:* images already carry an unprivileged `node` user at uid 1000, which
# matches the first user on most Linux desktops — bind-mounted repos stay
# writable without a chown dance.
ENV APP_DIR=/opt/munder-difflin \
    HOME=/home/node \
    NPM_CONFIG_PREFIX=/home/node/.npm-global \
    PATH=/home/node/.npm-global/bin:/opt/munder-difflin/node_modules/.bin:$PATH \
    ELECTRON_DISABLE_SECURITY_WARNINGS=1 \
    DISPLAY_NUM=99 \
    SCREEN_GEOMETRY=1600x1000x24 \
    VNC_PORT=5900 \
    NOVNC_PORT=6080

WORKDIR ${APP_DIR}

# Only what the app needs at runtime. node_modules is copied whole on purpose:
# electron itself is a devDependency, and the native addons were built against
# its ABI in stage 1 — `npm prune --omit=dev` would delete the runtime.
COPY --from=builder --chown=node:node /opt/munder-difflin/node_modules ./node_modules
COPY --from=builder --chown=node:node /opt/munder-difflin/out ./out
COPY --chown=node:node package.json CHANGELOG.md ./
# Unpackaged (this image runs `electron <appDir>`, not an electron-builder
# bundle), so the main process resolves sidecars from the repo layout under
# app.getAppPath(): resources/ for md-slack-reply.cjs, kg.cjs and the bundled
# skills, and src/main/kg-core.cjs for the Knowledge Graph CLI's core.
COPY --chown=node:node resources ./resources
COPY --chown=node:node src/main/kg-core.cjs ./src/main/kg-core.cjs

COPY docker/entrypoint.sh docker/run-app.sh /usr/local/bin/
COPY docker/openbox-rc.xml /etc/openbox-rc.xml
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/run-app.sh

# Self-installed CLIs (~/.npm-global), agent logins (~/.claude) and the app's
# own userData (~/.config/munder-difflin) all live here — mount a volume on
# /home/node to keep them across `docker compose down`.
#
# /tmp/.X11-unix is where Xvfb binds its socket — pre-create it, since the
# container runs unprivileged.
RUN mkdir -p /home/node/.npm-global /workspace /tmp/.X11-unix \
 && chown -R node:node /home/node /workspace \
 && chmod 1777 /tmp/.X11-unix

USER node

EXPOSE 5900 6080

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/usr/local/bin/run-app.sh"]
