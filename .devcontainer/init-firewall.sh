#!/bin/bash
set -euo pipefail

echo "=================================================="
echo "Initializing Kanton BS Egress Firewall"
echo "=================================================="

# Check for root / capability
if ! iptables -L -n >/dev/null 2>&1; then
    echo "[WARNING] iptables is not functional. Ensure container is started with --cap-add=NET_ADMIN --cap-add=NET_RAW." >&2
    exit 1
fi

# Reset existing rules
iptables -F
iptables -X
iptables -t nat -F || true
iptables -t nat -X || true
iptables -t mangle -F || true
iptables -t mangle -X || true

# 1. Allow Loopback traffic
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# 2. Allow Established and Related connections
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# 3. Restrict DNS strictly to nameservers in /etc/resolv.conf
echo "Configuring nameserver access from /etc/resolv.conf..."
NAMESERVERS=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf)
for ns in $NAMESERVERS; do
    echo "  -> Allowing DNS to nameserver: $ns"
    iptables -A OUTPUT -p udp -d "$ns" --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp -d "$ns" --dport 53 -j ACCEPT
done

# 4. Define allowed domain list
ALLOWED_DOMAINS=(
    "api.anthropic.com"
    "auth.anthropic.com"
    "statsig.anthropic.com"
    "api.openai.com"
    "auth.openai.com"
    "chatgpt.com"
    "platform.openai.com"
    "registry.npmjs.org"
    "registry.yarnpkg.com"
    "pypi.org"
    "files.pythonhosted.org"
    "marketplace.visualstudio.com"
    "update.code.visualstudio.com"
    "vscode.blob.core.windows.net"
)

# Positive self-test target. Must be an allowed host that is expected to answer.
VERIFY_URL="https://api.github.com"

# 5. Build the allowlist.
#    The set is hash:net so it can hold both single addresses and CIDR ranges.
echo "Resolving allowed endpoints..."
ipset destroy allowed_hosts 2>/dev/null || true
ipset create allowed_hosts hash:net family inet

# 5a. GitHub publishes its address ranges. Resolving github.com by name is not
#     enough: it answers with a single, rotating A record, so the address seen
#     at startup is usually not the address used later and git over HTTPS fails.
echo "  -> Fetching GitHub address ranges from api.github.com/meta"
gh_ranges=$(curl -s --connect-timeout 10 https://api.github.com/meta \
            | jq -r '(.web // [])[], (.api // [])[], (.git // [])[], (.packages // [])[]' 2>/dev/null \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' || true)
if [ -z "$gh_ranges" ]; then
    echo "[ERROR] Could not fetch GitHub address ranges. Refusing to continue with an" >&2
    echo "        incomplete allowlist; git access would fail intermittently." >&2
    exit 1
fi
gh_count=0
for cidr in $gh_ranges; do
    ipset add allowed_hosts "$cidr" 2>/dev/null && gh_count=$((gh_count + 1)) || true
done
echo "     added $gh_count GitHub ranges"

# 5b. Remaining domains by name. Each is resolved several times, because
#     CDN-backed names hand out a rotating subset of their addresses and one
#     query does not reveal the whole set.
for domain in "${ALLOWED_DOMAINS[@]}"; do
    ips=""
    for _ in 1 2 3; do
        ips="$ips $(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
    done
    ips=$(echo "$ips" | tr ' ' '\n' | sort -u | grep -v '^$' || true)
    if [ -n "$ips" ]; then
        for ip in $ips; do
            ipset add allowed_hosts "$ip" 2>/dev/null || true
        done
        echo "  -> Allowed domain: $domain ($(echo "$ips" | wc -l) addresses)"
    else
        echo "  -> [WARNING] Could not resolve $domain (may be temporarily unreachable)"
    fi
done

# Add HTTPS / HTTP rules using ipset
iptables -A OUTPUT -p tcp -m set --match-set allowed_hosts dst -m multiport --dports 80,443 -j ACCEPT

# 6. Set default DROP policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

echo "=================================================="
echo "Firewall active. Default policy: DROP"
echo "=================================================="

# 7. Self-test: both directions must hold.
echo "Running verification self-test..."

# 7a. Negative: a target outside the allowlist must be unreachable.
#     1.1.1.1 is reachable on port 53 as a nameserver, so port 80 is probed.
if curl -s --connect-timeout 3 http://1.1.1.1 >/dev/null 2>&1; then
    echo "[ERROR] Security verification FAILED: non-allowlisted target (1.1.1.1) was reachable!" >&2
    exit 1
fi
echo "[OK] Non-allowlisted egress is blocked."

# 7b. Positive: an allowlisted target must be reachable. Without this check a
#     firewall that blocks everything looks healthy while no work is possible.
if ! curl -s --connect-timeout 10 -o /dev/null "$VERIFY_URL"; then
    echo "[ERROR] Verification FAILED: allowlisted target ($VERIFY_URL) is NOT reachable." >&2
    echo "        The allowlist is incomplete or DNS is not working." >&2
    exit 1
fi
echo "[OK] Allowlisted egress works ($VERIFY_URL)."

echo "[OK] Egress firewall initialized and verified successfully."
