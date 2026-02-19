# syntax=docker/dockerfile:1
# Optimized for Oracle Ampere (ARM64) - Final Stable Version

# Stage 1: Base system dependencies
FROM node:lts-bookworm-slim AS base

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_ROOT_USER_ACTION=ignore

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl wget git build-essential software-properties-common \
    python3 python3-pip python3-venv python3-dev jq lsof \
    openssl ca-certificates gnupg ripgrep fd-find fzf bat \
    pandoc poppler-utils ffmpeg imagemagick graphviz sqlite3 \
    libsqlite3-dev pass chromium unzip netcat-openbsd \
    && ln -s /usr/bin/python3 /usr/bin/python \
    && rm -rf /var/lib/apt/lists/*

# Stage 2: System CLI tools
FROM base AS system-tools
RUN apt-get update && \
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list && \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null && \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends docker-ce-cli gh && \
    ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "amd64" ]; then GO_ARCH="amd64"; else GO_ARCH="arm64"; fi && \
    curl -fsSL "https://go.dev/dl/go1.23.4.linux-${GO_ARCH}.tar.gz" | tar -C /usr/local -xzf - && \
    curl -fsSL -o cloudflared.deb "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}.deb" && \
    dpkg -i cloudflared.deb && rm cloudflared.deb && \
    curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR="/usr/local/bin" sh && \
    rm -rf /var/lib/apt/lists/*

# Stage 3: Language runtimes
FROM system-tools AS runtimes
ENV BUN_INSTALL_NODE=0 \
    BUN_INSTALL="/data/.bun" \
    VIRTUAL_ENV="/opt/venv" \
    PATH="/opt/venv/bin:/usr/local/go/bin:/data/.bun/bin:/data/.bun/install/global/bin:$PATH"

RUN python3 -m venv $VIRTUAL_ENV && curl -fsSL https://bun.sh/install | bash
RUN uv pip install ipython csvkit openpyxl python-docx pypdf botasaurus browser-use playwright && \
    playwright install-deps
ENV XDG_CACHE_HOME="/data/.cache"
RUN ln -s /usr/bin/fdfind /usr/bin/fd || true && ln -s /usr/bin/batcat /usr/bin/bat || true

# Stage 4: Application dependencies
FROM runtimes AS dependencies

# 🦞 CRITICAL FIX FOR EXIT CODE 127
# Re-asserting build tools and node-gyp inside this specific stage
USER root
ENV PYTHON=/usr/bin/python3
RUN apt-get update && apt-get install -y python3 python3-dev make g++ gcc && \
    npm install -g node-gyp && \
    rm -rf /var/lib/apt/lists/*

ARG OPENCLAW_BETA=false
ARG OPENCLAW_VERSION=2026.2.17
ENV OPENCLAW_BETA=${OPENCLAW_BETA} \
    OPENCLAW_NO_ONBOARD=1 \
    NPM_CONFIG_UNSAFE_PERM=true \
    OPENCLAW_VERSION=${OPENCLAW_VERSION}

# Install tools and OpenClaw
RUN --mount=type=cache,target=/data/.bun/install/cache \
    bun install -g vercel @marp-team/marp-cli https://github.com/tobi/qmd && \
    bun install -g @openai/codex @google/gemini-cli opencode-ai @steipete/summarize @hyperbrowser/agent clawhub

RUN --mount=type=cache,target=/data/.npm \
    npm install -g pnpm openclaw@${OPENCLAW_VERSION}

# AI Tool Suite & ClawHub
RUN curl -fsSL https://claude.ai/install.sh | bash && \
    curl -fsSL https://code.kimi.com/install.sh | bash

# Stage 5: Final
FROM dependencies AS final
WORKDIR /app
COPY . .
RUN ln -sf /data/.claude/bin/claude /usr/local/bin/claude 2>/dev/null || true && \
    ln -sf /data/.kimi/bin/kimi /usr/local/bin/kimi 2>/dev/null || true && \
    ln -sf /app/scripts/openclaw-approve.sh /usr/local/bin/openclaw-approve && \
    chmod +x /app/scripts/*.sh /usr/local/bin/openclaw-approve

ENV PATH="/opt/venv/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:/data/.local/bin:/data/.npm-global/bin:/data/.bun/bin:/data/.bun/install/global/bin:/data/.claude/bin:/data/.kimi/bin"

ARG PORT=18790
EXPOSE ${PORT}
CMD ["bash", "/app/scripts/bootstrap.sh"]
