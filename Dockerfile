FROM node:lts-bookworm-slim

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install Core & Power Tools
# Note: Debian "slim" images are minimal. We need to install common tools.
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    wget \
    git \
    build-essential \
    software-properties-common \
    python3 \
    python3-pip \
    python3-venv \
    jq \
    lsof \
    openssl \
    ca-certificates \
    golang-go \
    gnupg \
    # Power Tools: ripgrep, fd, fzf, bat
    ripgrep fd-find fzf bat \
    # Document & Office Tools: pandoc, pdf, images
    pandoc \
    poppler-utils \
    ffmpeg \
    imagemagick \
    graphviz \
    sqlite3 \
    # Security: Pass (GPG)
    pass \
    && rm -rf /var/lib/apt/lists/*

# Install rbw (Bitwarden CLI) - Support both AMD64 and ARM64
# Temporarily disabled for ARM64 compatibility - building from source is required or valid deb url
# RUN ARCH=$(dpkg --print-architecture) && \
#     if [ "$ARCH" = "amd64" ]; then \
#     URL="https://git.tozt.net/rbw/releases/deb/rbw_1.12.1_amd64.deb"; \
#     elif [ "$ARCH" = "arm64" ]; then \
#     URL="https://git.tozt.net/rbw/releases/deb/rbw_1.12.1_arm64.deb"; \
#     else \
#     echo "Unsupported architecture: $ARCH" && exit 1; \
#     fi && \
#     curl -L --output rbw.deb "$URL" && \
#     dpkg -i rbw.deb && \
#     rm rbw.deb

# Install Cloudflare Tunnel (cloudflared)
RUN ARCH=$(dpkg --print-architecture) && \
    curl -L --output cloudflared.deb "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}.deb" && \
    dpkg -i cloudflared.deb && \
    rm cloudflared.deb

# Install GitHub CLI (gh)
RUN mkdir -p -m 755 /etc/apt/keyrings && \
    wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null && \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
    apt-get update && \
    apt-get install -y gh && \
    rm -rf /var/lib/apt/lists/*

# Install uv (Python tool manager)
ENV UV_INSTALL_DIR="/usr/local/bin"
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# Install Bun
# Note: Bun install script works better with unzip
RUN apt-get update && apt-get install -y unzip && rm -rf /var/lib/apt/lists/* && \
    curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

# Install Vercel & Marp (Slides) & QMD (Search)
# Node & NPM are already provided by base image
# QMD requires bun and global install
RUN npm install -g vercel @marp-team/marp-cli && \
    bun install -g https://github.com/tobi/qmd && \
    hash -r

# Configure QMD Persistence
ENV XDG_CACHE_HOME="/home/node/.moltbot/cache"

# Install Python Tools (IPython, Office Libs)
# Use --break-system-packages because we are in a container/appliance
RUN pip3 install ipython \
    csvkit \
    openpyxl \
    python-docx \
    pypdf \
    --break-system-packages

# Add aliases for standard tool names (Debian/Ubuntu quirks)
RUN ln -s /usr/bin/fdfind /usr/bin/fd || true && \
    ln -s /usr/bin/batcat /usr/bin/bat || true

# Set up working directory
WORKDIR /app

# Create necessary directories and set permissions
# 'node' user already exists in the base image
RUN mkdir -p /home/node/.moltbot /home/node/molt && \
    chown -R node:node /home/node/.moltbot /home/node/molt /app

# Switch to non-root user for installation
USER node
WORKDIR /app

# Set PATH for global npm binaries
ENV PATH="/home/node/.npm-global/bin:${PATH}"

# Run Moltbot install scripts as 'node' user
# This ensures it installs to /home/node/.npm-global/bin
ARG MOLT_BOT_BETA=false
ENV MOLT_BOT_BETA=${MOLT_BOT_BETA} \
    CLAWDBOT_NO_ONBOARD=1
RUN curl -fsSL https://molt.bot/install.sh | bash && \
    ln -s /home/node/.npm-global/bin/clawdbot /home/node/.npm-global/bin/moltbot || true

# Copy local scripts (as node user since we already switched)
COPY --chown=node:node scripts/bootstrap.sh /app/scripts/bootstrap.sh
RUN chmod +x /app/scripts/bootstrap.sh

# Expose the application port
EXPOSE 18789

# Set entrypoint
CMD ["bash", "/app/scripts/bootstrap.sh"]