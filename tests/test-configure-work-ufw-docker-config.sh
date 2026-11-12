#!/usr/bin/env bash
set -euo pipefail
readonly ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly HARNESS="$ROOT/tests/test-configure-work-ufw-docker.sh"

bash -n "$HARNESS"
grep -Fqx "require_ipv6_baseline 'A: before enabling UFW'" "$HARNESS"
grep -Fqx "require_ipv6_baseline 'B: after enabling UFW, before custom policy'" "$HARNESS"
grep -Fq -- "curl -6 --noproxy '*'" "$HARNESS"
grep -Fq 'ip6tables-save -c' "$HARNESS"
test "$("$HARNESS" --validate-ipv6-subnet)" = 'valid Docker IPv6 test subnet: fd42:4757:2026:1::/64'
test "$(DOCKER_UFW_IPV6_SUBNET='fd42:4757:2026:99::/64' "$HARNESS" --validate-ipv6-subnet)" = 'valid Docker IPv6 test subnet: fd42:4757:2026:99::/64'
if DOCKER_UFW_IPV6_SUBNET='2001:db8::/64' "$HARNESS" --validate-ipv6-subnet >/dev/null 2>&1; then
    echo 'expected non-ULA IPv6 subnet rejection' >&2; exit 1
fi
if DOCKER_UFW_IPV6_SUBNET='fd42:4757:2026::/48' "$HARNESS" --validate-ipv6-subnet >/dev/null 2>&1; then
    echo 'expected non-/64 IPv6 subnet rejection' >&2; exit 1
fi
fixture="$(mktemp -d /tmp/gpt-work-ufw-docker-config.XXXXXX)"
trap 'rm -rf -- "$fixture"' EXIT
cat >"$fixture/docker" <<'STUB'
#!/bin/bash
set -euo pipefail
case "$1" in
    info|rm) exit 0 ;;
    build)
        context="${@: -1}"
        files="$(find "$context" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)"
        test "$files" = "$(printf '%s\n' Dockerfile configure-work-ufw-policy.sh)"
        printf '%s\n' "$context" >"$CONTEXT_LOG"
        exit 77
        ;;
    *) exit 98 ;;
esac
STUB
chmod 700 "$fixture/docker"
if PATH="$fixture:$PATH" CONTEXT_LOG="$fixture/context" "$HARNESS"; then
    echo 'expected the mocked build to stop the harness' >&2
    exit 1
else
    test "$?" = 77
fi
test ! -e "$(cat "$fixture/context")"
echo 'Docker subnet and build-context checks passed; Docker was mocked'
