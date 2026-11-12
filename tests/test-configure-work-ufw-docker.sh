#!/usr/bin/env bash
# Real kernel-firewall integration test: disposable Docker resources only.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
run="$$-$RANDOM"
tag="gpt-work-ufw-it:$run"
net4="gpt-work-ufw-it4-$run"
net6="gpt-work-ufw-it6-$run"
fw4="gpt-work-ufw-fw4-$run"
fw6="gpt-work-ufw-fw6-$run"
a4="gpt-work-ufw-a4-$run"; b4="gpt-work-ufw-b4-$run"
a6="gpt-work-ufw-a6-$run"; b6="gpt-work-ufw-b6-$run"
ipv6_subnet="${DOCKER_UFW_IPV6_SUBNET:-fd42:4757:2026:1::/64}"
have_net4=0; have_net6=0; have_image=0
build_context=""

fail() { echo "FAIL: $*" >&2; exit 1; }
unsupported() { echo "UNSUPPORTED: $*" >&2; exit 2; }
validate_ipv6_subnet() {
    python3 - "$1" <<'PY'
import ipaddress
import sys
try:
    network = ipaddress.ip_network(sys.argv[1], strict=True)
except ValueError as error:
    raise SystemExit(f"invalid IPv6 subnet: {error}")
if network.version != 6 or network.prefixlen != 64 or network.network_address.packed[0] != 0xfd:
    raise SystemExit("IPv6 subnet must be a ULA fd00::/8 /64")
print(network)
PY
}
ipv6_subnet="$(validate_ipv6_subnet "$ipv6_subnet")" || fail "invalid DOCKER_UFW_IPV6_SUBNET: $ipv6_subnet"
if [[ "${1:-}" == --validate-ipv6-subnet ]]; then
    printf 'valid Docker IPv6 test subnet: %s\n' "$ipv6_subnet"
    exit 0
fi
[[ $# -eq 0 ]] || fail "unknown argument: $1"
check_ipv6_conflict() {
    local existing
    existing="$(docker network ls -q | xargs -r docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}')"
    DOCKER_UFW_EXISTING_SUBNETS="$existing" python3 - "$ipv6_subnet" <<'PY'
import ipaddress
import os
import sys
candidate = ipaddress.ip_network(sys.argv[1])
for raw in os.environ["DOCKER_UFW_EXISTING_SUBNETS"].splitlines():
    try:
        existing = ipaddress.ip_network(raw.strip(), strict=False)
    except ValueError:
        continue
    if existing.version == 6 and candidate.overlaps(existing):
        raise SystemExit(f"conflicting Docker IPv6 subnet: {existing}")
PY
}
cleanup() {
    if [[ -n "$build_context" ]]; then rm -rf -- "$build_context"; fi
    docker rm -f "$fw4" "$fw6" "$a4" "$b4" "$a6" "$b6" >/dev/null 2>&1 || true
    (( have_net4 )) && docker network rm "$net4" >/dev/null 2>&1 || true
    (( have_net6 )) && docker network rm "$net6" >/dev/null 2>&1 || true
    (( have_image )) && docker image rm -f "$tag" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

command -v docker >/dev/null 2>&1 || unsupported 'Docker CLI is unavailable'
docker info >/dev/null 2>&1 || unsupported 'Docker daemon is unavailable or inaccessible'
build_context="$(mktemp -d /tmp/gpt-work-ufw-build.XXXXXX)"
cp -- "$ROOT/configure-work-ufw-policy.sh" "$build_context/"
cp -- "$ROOT/tests/docker/ufw-firewall.Dockerfile" "$build_context/Dockerfile"
docker build --pull=false -t "$tag" "$build_context"
have_image=1
docker network create --internal "$net4" >/dev/null
have_net4=1

start_http4() {
    docker run -d --name "$1" --network "$net4" python:3.12-alpine \
        python3 -m http.server 8080 --bind 0.0.0.0 >/dev/null
}
start_http4 "$a4"; start_http4 "$b4"
docker run -d --name "$fw4" --network "$net4" --cap-add=NET_ADMIN "$tag" >/dev/null
docker exec "$fw4" ufw --force enable >/dev/null || fail 'UFW cannot enable with NET_ADMIN'
ip_a="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$a4")"
ip_b="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$b4")"
work4() { docker exec "$fw4" su -s /bin/sh -c "curl -4 -fsS --connect-timeout 3 http://$1:8080/" local-gpt-work; }
root4() { docker exec "$fw4" curl -4 -fsS --connect-timeout 3 "http://$1:8080/"; }
ready() { for _ in 1 2 3 4 5; do "$@" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
ready work4 "$ip_a" || fail 'Work UID cannot reach target A before policy'
ready work4 "$ip_b" || fail 'Work UID cannot reach target B before policy'

counter4() { docker exec "$fw4" iptables -L work-uid-output -v -n 2>/dev/null | awk 'NR>2 { sum += $1 } END { print sum+0 }'; }
docker exec "$fw4" /usr/local/sbin/configure-work-ufw-policy install --ipv4 "$ip_a"
docker exec "$fw4" iptables -S work-uid-output | grep -F -- "-d $ip_a" >/dev/null || fail 'installed IPv4 rule missing'
before="$(counter4)"
if work4 "$ip_a" >/dev/null 2>&1; then fail 'Work UID reached blocked target A'; fi
after="$(counter4)"
(( after > before )) || fail 'blocked request did not increment installed-rule counter'
root4 "$ip_a" >/dev/null || fail 'root UID lost access to target A'
work4 "$ip_b" >/dev/null || fail 'Work UID lost unlisted target B access'

docker exec "$fw4" /usr/local/sbin/configure-work-ufw-policy install --ipv4 "$ip_b"
work4 "$ip_a" >/dev/null || fail 'policy update did not restore target A access'
before="$(counter4)"; if work4 "$ip_b" >/dev/null 2>&1; then fail 'Work UID reached updated blocked target B'; fi; after="$(counter4)"
(( after > before )) || fail 'updated rule did not count rejected traffic'
normalized_before="$(docker exec "$fw4" iptables-save | awk '/work-uid-output|ufw-before-output/ {print}')"
docker exec "$fw4" /usr/local/sbin/configure-work-ufw-policy install --ipv4 "$ip_b"
test "$normalized_before" = "$(docker exec "$fw4" iptables-save | awk '/work-uid-output|ufw-before-output/ {print}')" || fail 'repeat installation changed normalized policy'
docker exec "$fw4" /usr/local/sbin/configure-work-ufw-policy remove
work4 "$ip_b" >/dev/null || fail 'policy removal did not restore target B connectivity'

# IPv6 is required for a complete PASS. Do not hide Docker's creation error.
check_ipv6_conflict || fail "refusing to create conflicting IPv6 test network: $ipv6_subnet"
docker network create --internal --ipv6 --subnet "$ipv6_subnet" "$net6" ||
    unsupported "Docker could not create isolated IPv6 network with $ipv6_subnet"
have_net6=1
for name in "$a6" "$b6"; do docker run -d --name "$name" --network "$net6" python:3.12-alpine python3 -m http.server 8080 --bind :: >/dev/null; done
docker run -d --name "$fw6" --network "$net6" --cap-add=NET_ADMIN "$tag" >/dev/null
v6a="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.GlobalIPv6Address}}{{end}}' "$a6")"
v6b="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.GlobalIPv6Address}}{{end}}' "$b6")"
[[ -n "$v6a" && -n "$v6b" ]] || unsupported 'Docker IPv6 network supplied no container IPv6 addresses'
work6() { docker exec "$fw6" su -s /bin/sh -c "curl -6 --noproxy '*' -fsS --connect-timeout 3 http://[$1]:8080/" local-gpt-work; }
root6() { docker exec "$fw6" curl -6 --noproxy '*' -fsS --connect-timeout 3 "http://[$1]:8080/"; }
diagnose_ipv6() {
    local phase="$1"
    {
        echo "IPv6 diagnostic: phase=$phase"
        echo "target A IPv6=$v6a target B IPv6=$v6b"
        echo '--- target A addresses/listeners ---'
        docker exec "$a6" sh -c 'ip -6 addr; ip -6 route; ss -lnt6; ps -ef'
        echo '--- firewall addresses/routes ---'
        docker exec "$fw6" sh -c 'ip -6 addr; ip -6 route'
        echo '--- configured firewall proxy variable names ---'
        docker exec "$fw6" sh -c 'env | cut -d= -f1 | grep -iE "^(http|https|all|no)_proxy$" || true'
        echo '--- UFW status ---'
        docker exec "$fw6" ufw status verbose || true
        echo '--- ip6tables counters/rules ---'
        docker exec "$fw6" ip6tables-save -c || true
        echo '--- root curl -6 --noproxy result ---'
        docker exec "$fw6" sh -c "curl -6 --noproxy '*' -v --connect-timeout 3 http://[$v6a]:8080/" || true
        echo '--- local-gpt-work curl -6 --noproxy result ---'
        docker exec "$fw6" su -s /bin/sh -c "curl -6 --noproxy '*' -v --connect-timeout 3 http://[$v6a]:8080/" local-gpt-work || true
    } >&2
}
require_ipv6_baseline() {
    local phase="$1"
    root6 "$v6a" >/dev/null 2>&1 && work6 "$v6a" >/dev/null 2>&1 &&
        root6 "$v6b" >/dev/null 2>&1 && work6 "$v6b" >/dev/null 2>&1 && return 0
    diagnose_ipv6 "$phase"
    fail "IPv6 baseline connectivity failed during $phase"
}

# Phase A: Docker IPv6 connectivity before UFW is enabled.
require_ipv6_baseline 'A: before enabling UFW'
docker exec "$fw6" ufw --force enable >/dev/null || fail 'IPv6 UFW cannot enable with NET_ADMIN'
# Phase B: UFW baseline must work before the Work UID policy is installed.
require_ipv6_baseline 'B: after enabling UFW, before custom policy'
# Phase C: custom policy blocks only the Work UID and only the listed target.
docker exec "$fw6" /usr/local/sbin/configure-work-ufw-policy install --ipv4 192.0.2.1 --ipv6 "$v6a"
docker exec "$fw6" ip6tables -S work-uid-output | grep -F -- "-d $v6a" >/dev/null || fail 'installed IPv6 rule missing'
if work6 "$v6a" >/dev/null 2>&1; then fail 'Work UID reached blocked IPv6 target A'; fi
work6 "$v6b" >/dev/null || fail 'Work UID lost permitted IPv6 target B access'
# Phase D: removal restores access.
docker exec "$fw6" /usr/local/sbin/configure-work-ufw-policy remove
work6 "$v6a" >/dev/null || fail 'IPv6 removal did not restore target A connectivity'
echo 'PASS: IPv4 and IPv6 Docker UFW integration tests completed'
