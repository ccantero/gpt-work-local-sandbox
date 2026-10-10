#!/bin/bash
set -euo pipefail

readonly ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly LAUNCHER="${ROOT}/run-work.sh"

# This test is intentionally static. Never execute the real launcher here:
# doing so would change graphical access and may change host firewall rules.
bash -n "${LAUNCHER}"
test -x "${LAUNCHER}"

require_text() {
    grep -Fq -- "$1" "${LAUNCHER}"
}

require_text 'WORK_USER="local-gpt-work"'
require_text 'PROD_VPS_IP="${PROD_VPS_IP:?ERROR: PROD_VPS_IP is required}"'
require_text 'trap cleanup EXIT INT TERM'
require_text 'xhost +SI:localuser:"$WORK_USER"'
require_text 'xhost -SI:localuser:"$WORK_USER"'
require_text 'sudo iptables -C OUTPUT'
require_text 'sudo iptables -A OUTPUT'
require_text 'sudo iptables -D OUTPUT'
require_text 'sudo -u "$WORK_USER" -H'
require_text 'DISPLAY="$DISPLAY"'
require_text 'XDG_RUNTIME_DIR="/run/user/$WORK_UID"'
require_text 'DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$WORK_UID/bus"'
require_text '/usr/bin/chatgpt --ozone-platform=x11'

echo "Static Work launcher checks passed; launcher was not executed"
