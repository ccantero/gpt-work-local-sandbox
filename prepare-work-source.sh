#!/bin/bash
set -euo pipefail
umask 077

usage() {
    echo "Usage: $0 <source-repository> <revision> <handoff-archive> <provenance-file>" >&2
    exit 64
}

if (( $# != 4 )); then usage; fi

readonly SOURCE_INPUT="$1"
readonly REVISION_INPUT="$2"
readonly ARCHIVE_INPUT="$3"
readonly PROVENANCE_INPUT="$4"

for command in git tar mktemp sha256sum date mv rm find readlink realpath chmod awk; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "ERROR: required command is unavailable: ${command}" >&2
        exit 69
    fi
done

if [[ ! -d "${SOURCE_INPUT}" ]]; then
    echo "ERROR: source repository is not a directory: ${SOURCE_INPUT}" >&2
    exit 66
fi

SOURCE="$(realpath -e -- "${SOURCE_INPUT}")"
ARCHIVE="$(realpath -m -- "${ARCHIVE_INPUT}")"
PROVENANCE="$(realpath -m -- "${PROVENANCE_INPUT}")"
readonly SOURCE ARCHIVE PROVENANCE
readonly ARCHIVE_PARENT="${ARCHIVE%/*}"
readonly PROVENANCE_PARENT="${PROVENANCE%/*}"

if [[ "${ARCHIVE}" == "/" || "${PROVENANCE}" == "/" || "${ARCHIVE}" == "${PROVENANCE}" ]]; then
    echo "ERROR: archive and provenance must be distinct non-root paths" >&2
    exit 64
fi
if [[ ! -d "${ARCHIVE_PARENT}" || -L "${ARCHIVE_PARENT}" ]]; then
    echo "ERROR: archive parent must be an existing, non-symlink directory: ${ARCHIVE_PARENT}" >&2
    exit 73
fi
if [[ ! -d "${PROVENANCE_PARENT}" || -L "${PROVENANCE_PARENT}" ]]; then
    echo "ERROR: provenance parent must be an existing, non-symlink directory: ${PROVENANCE_PARENT}" >&2
    exit 73
fi
if [[ -e "${ARCHIVE}" || -L "${ARCHIVE}" ]]; then
    echo "ERROR: refusing to replace an existing handoff archive: ${ARCHIVE}" >&2
    exit 73
fi
if [[ -e "${PROVENANCE}" || -L "${PROVENANCE}" ]]; then
    echo "ERROR: refusing to replace existing provenance: ${PROVENANCE}" >&2
    exit 73
fi

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_COMMON_DIR
unset GIT_CONFIG_PARAMETERS GIT_DIR GIT_INDEX_FILE GIT_NAMESPACE
unset GIT_OBJECT_DIRECTORY GIT_WORK_TREE

if ! git -C "${SOURCE}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: source is not a Git working tree: ${SOURCE}" >&2
    exit 65
fi

UPSTREAM_COMMIT="$(git -C "${SOURCE}" rev-parse --verify "${REVISION_INPUT}^{commit}")" || {
    echo "ERROR: revision does not resolve to a commit: ${REVISION_INPUT}" >&2
    exit 65
}
UPSTREAM_TREE="$(git -C "${SOURCE}" show -s --format='%T' "${UPSTREAM_COMMIT}")"
UPSTREAM_DATE="$(git -C "${SOURCE}" show -s --format='%aI' "${UPSTREAM_COMMIT}")"
readonly UPSTREAM_COMMIT UPSTREAM_TREE UPSTREAM_DATE

if git -C "${SOURCE}" ls-tree -r "${UPSTREAM_COMMIT}" |
    awk '$1 == "160000" { found=1 } END { exit !found }'; then
    echo "ERROR: selected commit contains gitlinks; the handoff would not be self-contained" >&2
    exit 65
fi

ARCHIVE_TEMP=""
PROVENANCE_TEMP=""
VALIDATION_DIR=""
cleanup() {
    if [[ -n "${ARCHIVE_TEMP}" ]]; then rm -f -- "${ARCHIVE_TEMP}"; fi
    if [[ -n "${PROVENANCE_TEMP}" ]]; then rm -f -- "${PROVENANCE_TEMP}"; fi
    if [[ -n "${VALIDATION_DIR}" ]]; then rm -rf -- "${VALIDATION_DIR}"; fi
}
trap cleanup EXIT

ARCHIVE_TEMP="$(mktemp "${ARCHIVE_PARENT}/.prepare-work-source.XXXXXX.tar")"
PROVENANCE_TEMP="$(mktemp "${PROVENANCE_PARENT}/.prepare-work-source.XXXXXX.provenance")"
VALIDATION_DIR="$(mktemp -d "${ARCHIVE_PARENT}/.prepare-work-source.XXXXXX.validate")"

git -C "${SOURCE}" archive --format=tar --output="${ARCHIVE_TEMP}" "${UPSTREAM_COMMIT}"
tar -xf "${ARCHIVE_TEMP}" -C "${VALIDATION_DIR}" --no-same-owner --no-same-permissions

while IFS= read -r -d '' link; do
    link_target="$(readlink -- "${link}")"
    resolved_link="$(realpath -m -- "${link%/*}/${link_target}")"
    if [[ "${link_target}" == /* ]] ||
        [[ "${resolved_link}" != "${VALIDATION_DIR}" && "${resolved_link}" != "${VALIDATION_DIR}/"* ]]; then
        echo "ERROR: exported source contains a symlink escaping the snapshot: ${link#${VALIDATION_DIR}/}" >&2
        exit 65
    fi
done < <(find "${VALIDATION_DIR}" -type l -print0)

ARCHIVE_SHA256="$(sha256sum -- "${ARCHIVE_TEMP}")"
ARCHIVE_SHA256="${ARCHIVE_SHA256%%[[:space:]]*}"
PREPARED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
readonly ARCHIVE_SHA256 PREPARED_AT

{
    printf 'format=work-source-provenance-v2\n'
    printf 'upstream_commit=%s\n' "${UPSTREAM_COMMIT}"
    printf 'upstream_tree=%s\n' "${UPSTREAM_TREE}"
    printf 'upstream_author_date=%s\n' "${UPSTREAM_DATE}"
    printf 'archive_sha256=%s\n' "${ARCHIVE_SHA256}"
    printf 'prepared_at_utc=%s\n' "${PREPARED_AT}"
} > "${PROVENANCE_TEMP}"

# Publish read-only files to reduce accidental edits. This is a lifecycle aid,
# not a security boundary: local-gpt-work intentionally controls its handoff
# directory and may change or remove artifacts that it owns.
chmod 0444 -- "${ARCHIVE_TEMP}" "${PROVENANCE_TEMP}"

if ! mv -T --no-clobber -- "${PROVENANCE_TEMP}" "${PROVENANCE}"; then
    echo "ERROR: provenance path appeared during preparation" >&2
    exit 73
fi
PROVENANCE_TEMP=""
if ! mv -T --no-clobber -- "${ARCHIVE_TEMP}" "${ARCHIVE}"; then
    echo "ERROR: archive path appeared during preparation" >&2
    echo "WARNING: provenance was left for human review: ${PROVENANCE}" >&2
    exit 73
fi
ARCHIVE_TEMP=""

echo "Work source handoff prepared"
echo "  upstream commit: ${UPSTREAM_COMMIT}"
echo "  archive:         ${ARCHIVE}"
echo "  provenance:      ${PROVENANCE}"
