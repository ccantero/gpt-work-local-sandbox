#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly POLICY="${ROOT}/configure-work-ufw-policy.sh"

bash -n "$POLICY"
test -x "$POLICY"

fixture="$(mktemp -d /tmp/gpt-work-ufw-test.XXXXXX)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/etc/ufw" "$fixture/etc/default"
printf '%s\n' \
    '*filter' \
    ':ufw-before-output - [0:0]' \
    '-A ufw-before-output -o lo -j ACCEPT' \
    '-A ufw-before-output -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT' \
    'COMMIT' >"$fixture/etc/ufw/before.rules"
printf '%s\n' \
    '*filter' \
    ':ufw6-before-output - [0:0]' \
    '-A ufw6-before-output -o lo -j ACCEPT' \
    '-A ufw6-before-output -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT' \
    'COMMIT' >"$fixture/etc/ufw/before6.rules"
printf 'IPV6=yes\n' >"$fixture/etc/default/ufw"
chmod 0640 "$fixture/etc/ufw/before.rules"
chmod 0600 "$fixture/etc/ufw/before6.rules"
touch -d '2026-01-02 03:04:05 UTC' "$fixture/etc/ufw/before.rules"
touch -d '2025-02-03 04:05:06 UTC' "$fixture/etc/ufw/before6.rules"
cp -p "$fixture/etc/ufw/before.rules" "$fixture/original.rules"
cp -p "$fixture/etc/ufw/before6.rules" "$fixture/original6.rules"

metadata(){ stat -c '%u:%g:%a:%Y' -- "$1"; }
assert_file(){ cmp -s -- "$1" "$2" && test "$(metadata "$1")" = "$(metadata "$2")"; }
assert_originals(){ assert_file "$fixture/original.rules" "$fixture/etc/ufw/before.rules"; assert_file "$fixture/original6.rules" "$fixture/etc/ufw/before6.rules"; }
reset_fixture(){
    cp -p "$fixture/original.rules" "$fixture/etc/ufw/before.rules"
    cp -p "$fixture/original6.rules" "$fixture/etc/ufw/before6.rules"
    rm -f -- "$fixture/etc/ufw/before.rules.rollback."* "$fixture/etc/ufw/before6.rules.rollback."* \
        "$fixture/etc/ufw/before.rules.candidate."* "$fixture/etc/ufw/before6.rules.candidate."*
}
assert_recovery_artifacts(){
    compgen -G "$fixture/etc/ufw/before.rules.rollback.*" >/dev/null
    compgen -G "$fixture/etc/ufw/before6.rules.rollback.*" >/dev/null
}

"$POLICY" install --root "$fixture" --ipv4 192.0.2.44
grep -Fqx ':work-uid-output - [0:0]' "$fixture/etc/ufw/before.rules"
grep -Fqx -- '-A ufw-before-output -j work-uid-output' "$fixture/etc/ufw/before.rules"
grep -Fqx -- '-A work-uid-output -m owner --uid-owner '"$(id -u local-gpt-work)"' -d 192.0.2.44 -j REJECT --reject-with icmp-port-unreachable' "$fixture/etc/ufw/before.rules"
test "$(metadata "$fixture/etc/ufw/before.rules")" = "$(metadata "$fixture/original.rules")"
test "$(metadata "$fixture/etc/ufw/before6.rules")" = "$(metadata "$fixture/original6.rules")"

(
    exec 8>>"$fixture/etc/ufw/.gpt-work-policy.lock"
    flock -n 8
    if "$POLICY" remove --root "$fixture" >"$fixture/locked.log" 2>&1; then
        echo 'expected concurrent transaction rejection' >&2
        exit 1
    else
        test "$?" = 75
    fi
    grep -Fq 'another Work UFW policy change is running' "$fixture/locked.log"
)
grep -Fqx ':work-uid-output - [0:0]' "$fixture/etc/ufw/before.rules"

"$POLICY" install --root "$fixture" --ipv4 192.0.2.44 --ipv6 2001:db8::44 >/dev/null
grep -Fqx -- '-A ufw6-before-output -j work-uid-output' "$fixture/etc/ufw/before6.rules"
grep -Fqx -- '-A work-uid-output -m owner --uid-owner '"$(id -u local-gpt-work)"' -d 2001:db8::44 -j REJECT --reject-with icmp6-port-unreachable' "$fixture/etc/ufw/before6.rules"
"$POLICY" install --root "$fixture" --ipv4 192.0.2.44 >/dev/null
if grep -Fqx ':work-uid-output - [0:0]' "$fixture/etc/ufw/before6.rules"; then
    echo 'expected the IPv6 policy to be removed when omitted' >&2
    exit 1
fi

before_hash="$(sha256sum "$fixture/etc/ufw/before.rules")"
"$POLICY" install --root "$fixture" --ipv4 192.0.2.44 >/dev/null
test "$before_hash" = "$(sha256sum "$fixture/etc/ufw/before.rules")"
"$POLICY" remove --root "$fixture"
assert_originals
"$POLICY" remove --root "$fixture"

if "$POLICY" install --root "$fixture" --ipv4 999.0.2.44 >/dev/null 2>&1; then echo 'expected malformed IPv4 rejection' >&2; exit 1; fi
if "$POLICY" install --root "$fixture" --ipv4 192.0.2.44 --ipv6 '2001:db8:::44' >/dev/null 2>&1; then echo 'expected malformed IPv6 rejection' >&2; exit 1; fi

reset_fixture
if UFW_POLICY_TEST_VALIDATOR_MISSING=4 "$POLICY" install --root "$fixture" --ipv4 192.0.2.44 >/dev/null 2>&1; then echo 'expected missing IPv4 validator rejection' >&2; exit 1; fi
assert_originals
if UFW_POLICY_TEST_VALIDATOR_MISSING=6 "$POLICY" install --root "$fixture" --ipv4 192.0.2.44 --ipv6 2001:db8::44 >/dev/null 2>&1; then echo 'expected missing IPv6 validator rejection' >&2; exit 1; fi
assert_originals

reset_fixture
if output="$(UFW_POLICY_TEST_FAIL_IPV4_REPLACEMENT=1 "$POLICY" install --root "$fixture" --ipv4 192.0.2.45 2>&1)"; then echo 'expected IPv4 replacement failure' >&2; exit 1; fi
grep -Fqx 'ERROR: injected fixture IPv4 replacement failure' <<<"$output"
assert_originals

reset_fixture
if output="$(UFW_POLICY_TEST_FAIL_IPV4_REPLACEMENT=1 UFW_POLICY_TEST_FAIL_RESTORE=4 "$POLICY" install --root "$fixture" --ipv4 192.0.2.45 2>&1)"; then echo 'expected IPv4 restoration failure' >&2; exit 1; fi
grep -Fq 'ERROR: recovery artifacts retained:' <<<"$output"
assert_recovery_artifacts

reset_fixture
if output="$(UFW_POLICY_TEST_INTERRUPT_STAGE=replacement "$POLICY" install --root "$fixture" --ipv4 192.0.2.45 2>&1)"; then echo 'expected replacement interruption' >&2; exit 1; fi
grep -Fq 'during file replacement; attempting persistent-file restoration before UFW reload' <<<"$output"
assert_originals

reset_fixture
if output="$(UFW_POLICY_TEST_INTERRUPT_STAGE=first-reload "$POLICY" install --root "$fixture" --ipv4 192.0.2.45 2>&1)"; then echo 'expected first reload interruption' >&2; exit 1; fi
grep -Fq 'during the first UFW reload; effective firewall state may be inconsistent' <<<"$output"
assert_recovery_artifacts

reset_fixture
if output="$(UFW_POLICY_TEST_FAIL_FIRST_RELOAD=1 UFW_POLICY_TEST_INTERRUPT_STAGE=restoration "$POLICY" install --root "$fixture" --ipv4 192.0.2.45 2>&1)"; then echo 'expected restoration interruption' >&2; exit 1; fi
grep -Fq 'during file restoration after the first UFW reload failed; effective firewall state may be inconsistent' <<<"$output"
assert_recovery_artifacts

reset_fixture
if output="$(UFW_POLICY_TEST_FAIL_FIRST_RELOAD=1 UFW_POLICY_TEST_INTERRUPT_STAGE=rollback-reload "$POLICY" install --root "$fixture" --ipv4 192.0.2.45 2>&1)"; then echo 'expected rollback reload interruption' >&2; exit 1; fi
grep -Fq 'during the rollback UFW reload; effective firewall state may be inconsistent' <<<"$output"
assert_recovery_artifacts

reset_fixture
if UFW_POLICY_TEST_FAIL_IPV6_REPLACEMENT=1 "$POLICY" install --root "$fixture" --ipv4 192.0.2.45 >/dev/null 2>&1; then echo 'expected IPv6 replacement failure' >&2; exit 1; fi
assert_originals

reset_fixture
if UFW_POLICY_TEST_FAIL_FIRST_RELOAD=1 "$POLICY" install --root "$fixture" --ipv4 192.0.2.45 >/dev/null 2>&1; then echo 'expected first reload failure' >&2; exit 1; fi
assert_originals

reset_fixture
if UFW_POLICY_TEST_FAIL_FIRST_RELOAD=1 UFW_POLICY_TEST_FAIL_ROLLBACK_RELOAD=1 "$POLICY" install --root "$fixture" --ipv4 192.0.2.45 >/dev/null 2>&1; then echo 'expected rollback reload failure' >&2; exit 1; fi
assert_originals
assert_recovery_artifacts

reset_fixture
if UFW_POLICY_TEST_FAIL_FIRST_RELOAD=1 UFW_POLICY_TEST_FAIL_RESTORE=6 "$POLICY" install --root "$fixture" --ipv4 192.0.2.45 >/dev/null 2>&1; then echo 'expected file restoration failure' >&2; exit 1; fi
assert_file "$fixture/original.rules" "$fixture/etc/ufw/before.rules"
assert_recovery_artifacts

printf '%s\n' '# BEGIN gpt-work-local-sandbox work UID rules' >>"$fixture/etc/ufw/before.rules"
if "$POLICY" remove --root "$fixture" >/dev/null 2>&1; then echo 'expected duplicate marker rejection' >&2; exit 1; fi

escape="$(mktemp -d /tmp/gpt-work-ufw-escape.XXXXXX)"
trap 'rm -rf -- "$fixture" "$escape"' EXIT
ln -s /etc "$escape/link"
if "$POLICY" install --root "$escape/link" --ipv4 192.0.2.44 >/dev/null 2>&1; then echo 'expected symlink fixture-root rejection' >&2; exit 1; fi

echo 'UFW policy fixture checks passed; no live firewall was accessed'
