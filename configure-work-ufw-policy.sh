#!/usr/bin/env bash
# Reviewable source for a root-owned UFW helper; never run this checkout as root.
set -euo pipefail
umask 077
readonly WORK_USER=local-gpt-work
readonly INSTALLED_PATH=/usr/local/sbin/configure-work-ufw-policy
readonly DB='# BEGIN gpt-work-local-sandbox work UID declarations'
readonly DE='# END gpt-work-local-sandbox work UID declarations'
readonly RB='# BEGIN gpt-work-local-sandbox work UID rules'
readonly RE='# END gpt-work-local-sandbox work UID rules'
usage(){ printf '%s\n' 'Usage: configure-work-ufw-policy.sh install --ipv4 ADDRESS [--ipv6 ADDRESS]' '       configure-work-ufw-policy.sh remove'; }
valid_address(){ python3 - "$1" "$2" <<'PY'
import ipaddress,sys
try: ok=ipaddress.ip_address(sys.argv[2]).version==int(sys.argv[1])
except ValueError: ok=False
raise SystemExit(not ok)
PY
}
count(){ grep -Fxc "$2" "$1" || true; }
output_chain() {
 case "$1" in 4) printf '%s\n' ufw-before-output ;; 6) printf '%s\n' ufw6-before-output ;; *) return 2 ;; esac
}
validate_markers(){
 local f="$1" chain="$2" db de rb re dl dle rl rle hook est
 db="$(count "$f" "$DB")";de="$(count "$f" "$DE")";rb="$(count "$f" "$RB")";re="$(count "$f" "$RE")"
 [[ "$db:$de:$rb:$re" == 0:0:0:0 ]]&&return 0
 [[ "$db:$de:$rb:$re" == 1:1:1:1 ]] || { echo "ERROR: managed markers are missing or duplicated in $f" >&2; return 1; }
 dl="$(grep -nF "$DB" "$f"|cut -d: -f1)";dle="$(grep -nF "$DE" "$f"|cut -d: -f1)";rl="$(grep -nF "$RB" "$f"|cut -d: -f1)";rle="$(grep -nF "$RE" "$f"|cut -d: -f1)"
 hook="$(grep -nFx -- "-A $chain -j work-uid-output" "$f"|cut -d: -f1)";est="$(grep -nFx -- "-A $chain -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT" "$f"|cut -d: -f1)"
 [[ "$dl" -lt "$dle" && "$dle" -lt "$rl" && "$rl" -lt "$rle" && -n "$hook" && "$hook" -lt "$est" ]] || { echo "ERROR: managed block ordering is unsafe in $f" >&2; return 1; }
 [[ "$(count "$f" ':work-uid-output - [0:0]')" == 1 ]] || { echo "ERROR: work chain declaration is missing or duplicated in $f" >&2; return 1; }
}
validate_shape(){
 local f="$1" family="$2" chain
 chain="$(output_chain "$family")" || { echo "ERROR: unsupported address family: $family" >&2; return 1; }
 [[ -f "$f" && ! -L "$f" ]] || { echo "ERROR: missing or symlinked UFW file: $f" >&2; return 1; }
 [[ "$(count "$f" '*filter')" == 1 ]] || { echo "ERROR: expected exactly one *filter table in $f" >&2; return 1; }
 grep -Fqx ":$chain - [0:0]" "$f" && grep -Fqx -- "-A $chain -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT" "$f" || { echo "ERROR: unsupported UFW output chain shape in $f" >&2; return 1; }
 validate_markers "$f" "$chain"
}
strip(){ awk -v db="$DB" -v de="$DE" -v rb="$RB" -v re="$RE" '$0==db||$0==rb{s=1;next}$0==de||$0==re{s=0;next}!s{print}' "$1" >"$2"; }
candidate_install(){
 local src="$1" out="$2" family="$3" uid="$4" reject=icmp-port-unreachable tmp chain;shift 4;[[ "$family" == 6 ]]&&reject=icmp6-port-unreachable
 chain="$(output_chain "$family")";validate_shape "$src" "$family";tmp="$(mktemp "$out.strip.XXXXXX")";trap 'rm -f -- "$tmp"' RETURN;strip "$src" "$tmp"
 awk -v db="$DB" -v de="$DE" -v rb="$RB" -v re="$RE" -v chain="$chain" -v uid="$uid" -v reject="$reject" -v addresses="$*" '
 /^-A /&&!d{print db;print ":work-uid-output - [0:0]";print de;d=1}
 $0=="-A "chain" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"{print rb;print "-A "chain" -j work-uid-output";n=split(addresses,a," ");for(i=1;i<=n;i++)print "-A work-uid-output -m owner --uid-owner "uid" -d "a[i]" -j REJECT --reject-with "reject;print re}{print}' "$tmp" >"$out"
 rm -f -- "$tmp";trap - RETURN;chmod --reference="$src" "$out";chown --reference="$src" "$out";touch -r "$src" "$out";validate_shape "$out" "$family";same_metadata "$src" "$out" || { echo "ERROR: candidate metadata differs from $src" >&2; return 1; }
}
metadata(){ stat -c '%u:%g:%a:%Y' -- "$1"; }
same_metadata(){ [[ "$(metadata "$1")" == "$(metadata "$2")" ]]; }
candidate_remove(){ validate_shape "$1" "$3";strip "$1" "$2";chmod --reference="$1" "$2";chown --reference="$1" "$2";touch -r "$1" "$2";validate_shape "$2" "$3";same_metadata "$1" "$2" || { echo "ERROR: candidate metadata differs from $1" >&2; return 1; }; }
validate_restore() {
 local family="$1" candidate="$2" fixture="$3" cmd=iptables-restore
 [[ "$family" == 6 ]] && cmd=ip6tables-restore
 if [[ "$fixture" == 1 ]]; then
  [[ "${UFW_POLICY_TEST_VALIDATOR_MISSING:-}" != "$family" ]] || { echo "ERROR: required $cmd is unavailable" >&2; return 1; }
  return 0
 fi
 command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: required validation utility is unavailable: $cmd" >&2; return 1; }
 "$cmd" --test <"$candidate" || { echo "ERROR: $cmd --test rejected generated candidate" >&2; return 1; }
}
backup_file(){
 local src="$1" backup="$2"
 cp -p -- "$src" "$backup" && cmp -s -- "$src" "$backup" && same_metadata "$src" "$backup"
}
atomic_restore_file(){
 local target="$1" backup="$2" family="$3" fixture="$4" tmp
 if [[ "$fixture" == 1 && "${UFW_POLICY_TEST_FAIL_RESTORE:-}" == "$family" ]]; then
  echo "ERROR: injected fixture restoration failure for IPv$family" >&2; return 1
 fi
 tmp="$(mktemp "${target}.restore.XXXXXX")"
 if ! cp -p -- "$backup" "$tmp" || ! cmp -s -- "$backup" "$tmp" || ! same_metadata "$backup" "$tmp"; then
  rm -f -- "$tmp"; echo "ERROR: could not stage restoration for $target" >&2; return 1
 fi
 if ! mv -T -- "$tmp" "$target" || ! cmp -s -- "$backup" "$target" || ! same_metadata "$backup" "$target"; then
  rm -f -- "$tmp"; echo "ERROR: could not atomically restore $target" >&2; return 1
 fi
}
restore_files(){
 local f4="$1" b4="$2" f6="$3" b6="$4" fixture="$5" status=0
 atomic_restore_file "$f4" "$b4" 4 "$fixture" || status=1
 atomic_restore_file "$f6" "$b6" 6 "$fixture" || status=1
 return "$status"
}
preserve_recovery(){
 TX_ACTIVE=0
 echo "ERROR: recovery artifacts retained: $ROLLBACK4 $ROLLBACK6" >&2
}
recover_replacement_failure(){
 echo 'ERROR: file replacement interrupted or failed; restoring both original files' >&2
 if ! restore_files "$f4" "$ROLLBACK4" "$f6" "$ROLLBACK6" "$fixture"; then preserve_recovery; return 1; fi
 rm -f -- "$ROLLBACK4" "$ROLLBACK6"; TX_ACTIVE=0; return 1
}
handle_interruption(){
 local signal="$1"
 trap - HUP INT TERM
 if (( TX_ACTIVE )) && [[ "$TX_STAGE" == replacing4 || "$TX_STAGE" == replaced4 || "$TX_STAGE" == replacing6 || "$TX_STAGE" == replaced6 ]]; then
  echo "ERROR: interrupted by $signal during file replacement; attempting persistent-file restoration before UFW reload" >&2
  recover_replacement_failure || true
 elif (( TX_ACTIVE )) && [[ "$TX_STAGE" == restoring ]]; then
  echo "ERROR: interrupted by $signal during file restoration after the first UFW reload failed; effective firewall state may be inconsistent" >&2
  preserve_recovery
 elif (( TX_ACTIVE )) && [[ "$TX_STAGE" == reloading ]]; then
  echo "ERROR: interrupted by $signal during the first UFW reload; effective firewall state may be inconsistent" >&2
  preserve_recovery
 elif (( TX_ACTIVE )) && [[ "$TX_STAGE" == rollback-reloading ]]; then
  echo "ERROR: interrupted by $signal during the rollback UFW reload; effective firewall state may be inconsistent" >&2
  preserve_recovery
 elif (( TX_ACTIVE )); then
  echo "ERROR: interrupted by $signal during UFW transaction stage $TX_STAGE; effective firewall state may be inconsistent" >&2
  preserve_recovery
 fi
 exit 128
}
apply_or_rollback(){
 f4="$1"; c4="$2"; f6="$3"; c6="$4"; fixture="$5"
 ROLLBACK4="$(mktemp "$f4.rollback.XXXXXX")"; ROLLBACK6="$(mktemp "$f6.rollback.XXXXXX")"
 if ! backup_file "$f4" "$ROLLBACK4" || ! backup_file "$f6" "$ROLLBACK6"; then
  rm -f -- "$ROLLBACK4" "$ROLLBACK6"; echo 'ERROR: could not create verified UFW rollback copies' >&2; return 1
 fi
 TX_ACTIVE=1; TX_STAGE=replacing4
 if [[ "$fixture" == 1 && "${UFW_POLICY_TEST_FAIL_IPV4_REPLACEMENT:-}" == 1 ]]; then
  echo 'ERROR: injected fixture IPv4 replacement failure' >&2; recover_replacement_failure; return 1
 fi
 if ! same_metadata "$c4" "$ROLLBACK4" || ! mv -T -- "$c4" "$f4"; then
  echo 'ERROR: IPv4 replacement failed; attempting restoration of both original files' >&2
  recover_replacement_failure; return 1
 fi
 TX_STAGE=replaced4
 if [[ "$fixture" == 1 && "${UFW_POLICY_TEST_INTERRUPT_STAGE:-}" == replacement ]]; then handle_interruption TERM; fi
 if [[ "$fixture" == 1 && "${UFW_POLICY_TEST_FAIL_IPV6_REPLACEMENT:-}" == 1 ]]; then
  echo 'ERROR: injected fixture IPv6 replacement failure' >&2; recover_replacement_failure; return 1
 fi
 TX_STAGE=replacing6
 same_metadata "$c6" "$ROLLBACK6" && mv -T -- "$c6" "$f6" || { echo 'ERROR: IPv6 replacement failed' >&2; recover_replacement_failure; return 1; }
 TX_STAGE=replaced6
}
run_reload(){
 local phase="$1"
 if [[ "$fixture" == 1 ]]; then
  if [[ "${UFW_POLICY_TEST_INTERRUPT_STAGE:-}" == "$phase-reload" ]]; then handle_interruption TERM; fi
  case "$phase" in first) [[ "${UFW_POLICY_TEST_FAIL_FIRST_RELOAD:-}" != 1 ]] ;; rollback) [[ "${UFW_POLICY_TEST_FAIL_ROLLBACK_RELOAD:-}" != 1 ]] ;; esac
 else
  ufw reload
 fi
}
reload_or_rollback(){
 f4="$1"; f6="$2"; fixture="$3"; TX_STAGE=reloading
 if run_reload first; then rm -f -- "$ROLLBACK4" "$ROLLBACK6"; TX_ACTIVE=0; return 0; fi
 echo 'ERROR: UFW reload failed; restoring both original UFW files' >&2
 TX_STAGE=restoring
 if [[ "$fixture" == 1 && "${UFW_POLICY_TEST_INTERRUPT_STAGE:-}" == restoration ]]; then handle_interruption TERM; fi
 if ! restore_files "$f4" "$ROLLBACK4" "$f6" "$ROLLBACK6" "$fixture"; then
  echo 'ERROR: original UFW files could not be fully restored' >&2; preserve_recovery; return 1
 fi
 TX_STAGE=rollback-reloading
 if ! run_reload rollback; then
  echo 'ERROR: original UFW files were restored, but UFW reload after rollback failed; active rules may be inconsistent' >&2
  preserve_recovery; return 1
 fi
 rm -f -- "$ROLLBACK4" "$ROLLBACK6"; TX_ACTIVE=0
 echo 'ERROR: UFW reload failed; original files were restored and reloaded' >&2
 return 1
}
action="${1:-}";[[ -n "$action" ]]&&shift||true;root=/;declare -a ipv4=() ipv6=()
while (($#));do case "$1" in --ipv4)ipv4+=("${2:?ERROR: --ipv4 needs an address}");shift 2;;--ipv6)ipv6+=("${2:?ERROR: --ipv6 needs an address}");shift 2;;--root)root="${2:?ERROR: --root needs a path}";shift 2;;-h|--help)usage;exit 0;;*)echo "ERROR: unknown option: $1" >&2;exit 2;;esac;done
case "$action" in
 install) ((${#ipv4[@]})) || { echo 'ERROR: at least one --ipv4 is required' >&2; exit 2; } ;;
 remove) ((${#ipv4[@]} == 0 && ${#ipv6[@]} == 0)) || { echo 'ERROR: remove takes no addresses' >&2; exit 2; } ;;
 *) usage >&2; exit 2 ;;
esac
fixture=0
if [[ "$root" == / ]]; then
 (( EUID == 0 )) || { echo 'ERROR: must run as root for live host' >&2; exit 1; }
 export PATH=/usr/sbin:/usr/bin:/sbin:/bin
 [[ "$(realpath -e -- "${BASH_SOURCE[0]}")" == "$INSTALLED_PATH" ]] || {
  echo "ERROR: run only the protected installed helper at $INSTALLED_PATH" >&2; exit 1;
 }
 command -v ufw >/dev/null || { echo 'ERROR: ufw is not installed' >&2; exit 1; }
else
 [[ -d "$root" && ! -L "$root" ]] || { echo 'ERROR: fixture root must be a real non-symlink directory' >&2; exit 2; }
 root="$(realpath -e -- "$root")"
 [[ "$root" == /tmp/* ]] || { echo 'ERROR: fixture root must resolve below /tmp' >&2; exit 2; }
 fixture=1
fi
for a in "${ipv4[@]}"; do valid_address 4 "$a" || { echo "ERROR: invalid IPv4 address: $a" >&2; exit 2; }; done
for a in "${ipv6[@]}"; do valid_address 6 "$a" || { echo "ERROR: invalid IPv6 address: $a" >&2; exit 2; }; done
declare -A seen=(); declare -a u4=() u6=()
for a in "${ipv4[@]}"; do [[ ${seen[4:$a]+x} ]] || { u4+=("$a"); seen[4:$a]=1; }; done
for a in "${ipv6[@]}"; do [[ ${seen[6:$a]+x} ]] || { u6+=("$a"); seen[6:$a]=1; }; done
ipv4=("${u4[@]}"); ipv6=("${u6[@]}")
f4="${root%/}/etc/ufw/before.rules"; f6="${root%/}/etc/ufw/before6.rules"
[[ -f "$f4" && -f "$f6" ]] || { echo 'ERROR: both UFW before rules files are required' >&2; exit 1; }
exec 9>>"${root%/}/etc/ufw/.gpt-work-policy.lock"
flock -n 9 || { echo 'ERROR: another Work UFW policy change is running' >&2; exit 75; }
if ((${#ipv6[@]})); then
 grep -Fqx 'IPV6=yes' "${root%/}/etc/default/ufw" || { echo 'ERROR: IPv6 addresses supplied but UFW IPv6 is not enabled' >&2; exit 1; }
fi
c4="$(mktemp "${f4}.candidate.XXXXXX")";c6="$(mktemp "${f6}.candidate.XXXXXX")";trap 'rm -f -- "$c4" "$c6"' EXIT;uid="$(id -u "$WORK_USER")";ROLLBACK4='';ROLLBACK6='';TX_ACTIVE=0;TX_STAGE=idle
trap 'handle_interruption HUP' HUP
trap 'handle_interruption INT' INT
trap 'handle_interruption TERM' TERM
if [[ "$action" == install ]];then candidate_install "$f4" "$c4" 4 "$uid" "${ipv4[@]}";if ((${#ipv6[@]}));then candidate_install "$f6" "$c6" 6 "$uid" "${ipv6[@]}";else candidate_remove "$f6" "$c6" 6;fi;else candidate_remove "$f4" "$c4" 4;candidate_remove "$f6" "$c6" 6;fi
validate_restore 4 "$c4" "$fixture";validate_restore 6 "$c6" "$fixture";apply_or_rollback "$f4" "$c4" "$f6" "$c6" "$fixture";reload_or_rollback "$f4" "$f6" "$fixture";trap - EXIT;echo "UFW Work UID policy $action completed"
