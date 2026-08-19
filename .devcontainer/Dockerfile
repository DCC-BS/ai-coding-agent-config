# Multi-platform DevContainer for Claude Code and OpenAI Codex
FROM mcr.microsoft.com/devcontainers/base:debian-12

USER root

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# 1. Install base utilities and firewall dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    iptables \
    iproute2 \
    squid \
    dnsutils \
    curl \
    wget \
    jq \
    git \
    ca-certificates \
    gnupg \
    python3 \
    python3-pip \
    python3-venv \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# 2. Install Node.js LTS (Node 20.x) for Claude Code and OpenAI Codex CLI
RUN mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# 3. Install Claude Code and OpenAI Codex CLI globally
RUN npm install -g @anthropic-ai/claude-code @openai/codex

# 4. Copy and lock down Claude Code reference configuration (/etc/claude-code/)
RUN mkdir -p /etc/claude-code
COPY managed-settings.json /etc/claude-code/managed-settings.json
RUN chown -R root:root /etc/claude-code \
    && chmod 0755 /etc/claude-code \
    && chmod 0444 /etc/claude-code/managed-settings.json

# 5. Copy and lock down OpenAI Codex reference configuration (/etc/codex/)
#    requirements.toml definiert die Profile und schränkt sie zugleich ein;
#    das frühere managed_config.toml wird nicht mehr benötigt.
RUN mkdir -p /etc/codex
COPY requirements.toml /etc/codex/requirements.toml
RUN chown -R root:root /etc/codex \
    && chmod 0755 /etc/codex \
    && chmod 0444 /etc/codex/requirements.toml

# 6. Copy and lock down the egress proxy configuration.
#    The allowlist filters by hostname, so it also covers connections made to a
#    raw IP address. An address-based firewall cannot do that.
COPY squid.conf /etc/squid/squid.conf
COPY allowlist.txt /etc/squid/allowlist.txt
RUN chown root:root /etc/squid/squid.conf /etc/squid/allowlist.txt \
    && chmod 0444 /etc/squid/squid.conf /etc/squid/allowlist.txt

# 7. Copy and configure the egress startup script
COPY init-egress.sh /usr/local/bin/init-egress.sh
RUN chown root:root /usr/local/bin/init-egress.sh \
    && chmod 0755 /usr/local/bin/init-egress.sh

# 8. Restrict sudo permissions for vscode user (only egress initialization allowed)
RUN rm -f /etc/sudoers.d/vscode \
    && echo "vscode ALL=(root) NOPASSWD: /usr/local/bin/init-egress.sh" > /etc/sudoers.d/010-egress \
    && chmod 0440 /etc/sudoers.d/010-egress

# 9. Route every client through the proxy. The firewall blocks anything else,
#    so a tool that ignores these variables simply has no network.
ENV HTTP_PROXY=http://127.0.0.1:3128 \
    HTTPS_PROXY=http://127.0.0.1:3128 \
    http_proxy=http://127.0.0.1:3128 \
    https_proxy=http://127.0.0.1:3128 \
    NO_PROXY=localhost,127.0.0.1 \
    no_proxy=localhost,127.0.0.1

# 10. Hier ergänzt jedes Projekt seine eigene Toolchain, z. B. uv mit einer
#     festen Python-Version, ein JDK, bun oder Node. Neue Paketquellen gehören
#     zusätzlich als Namen in allowlist.txt.

# Set unprivileged user.
# Hinweis: /workspace wird zur Laufzeit überdeckt (bind mount). Damit vscode
# dort schreiben kann, muss die Host-UID des Projektordners auf die UID von
# vscode abgebildet werden. Das ist bei rootful Docker und Docker Desktop der
# Fall, bei rootless Docker nicht (siehe README, Abschnitt "Rootless Docker").
USER vscode
WORKDIR /workspace
