#!/usr/bin/env bash
set -euo pipefail

WORK_USER="local-gpt-work"
WORK_UID="$(id -u "$WORK_USER")"

# Public IPv4 address of the production VPS.
# Block ALL outbound traffic from local-gpt-work to this host.
PROD_VPS_IP="${PROD_VPS_IP:?ERROR: PROD_VPS_IP is required}"

RULE_ADDED=0

cleanup() {
    if [[ "$RULE_ADDED" -eq 1 ]]; then
        sudo iptables -D OUTPUT \
            -m owner --uid-owner "$WORK_UID" \
            -d "$PROD_VPS_IP" \
            -j REJECT || true
    fi

    xhost -SI:localuser:"$WORK_USER" >/dev/null 2>&1 || true
}

trap cleanup EXIT INT TERM

# Allow GUI access for the isolated user.
xhost +SI:localuser:"$WORK_USER" >/dev/null

# Add the firewall rule only if it does not already exist.
if ! sudo iptables -C OUTPUT \
        -m owner --uid-owner "$WORK_UID" \
        -d "$PROD_VPS_IP" \
        -j REJECT \
        2>/dev/null; then

    sudo iptables -A OUTPUT \
        -m owner --uid-owner "$WORK_UID" \
        -d "$PROD_VPS_IP" \
        -j REJECT

    RULE_ADDED=1
fi

echo "Work sandbox:"
echo "  user:      $WORK_USER"
echo "  uid:       $WORK_UID"
echo "  PROD VPS:  $PROD_VPS_IP"
echo "  VPS access blocked for this user"

sudo -u "$WORK_USER" -H \
    env \
        DISPLAY="$DISPLAY" \
        XDG_RUNTIME_DIR="/run/user/$WORK_UID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$WORK_UID/bus" \
        /bin/sh -c 'cd "$HOME" && exec /usr/bin/chatgpt --ozone-platform=x11'
