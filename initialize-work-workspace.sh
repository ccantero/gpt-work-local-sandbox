#!/bin/bash
set -euo pipefail
umask 077

usage() {
    echo "Usage: $0 <handoff-archive> <provenance-file> <new-workspace>" >&2
    exit 64
}

if (( $# != 3 )); then usage; fi

readonly ARCHIVE_INPUT="$1"
readonly PROVENANCE_INPUT="$2"
readonly WORKSPACE_INPUT="$3"

for command in git tar mktemp sha256sum mv rm find readlink realpath grep sed; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "ERROR: required command is unavailable: ${command}" >&2
        exit 69
    fi
done

if [[ ! -f "${ARCHIVE_INPUT}" || -L "${ARCHIVE_INPUT}" ]]; then
    echo "ERROR: archive must be a regular, non-symlink file: ${ARCHIVE_INPUT}" >&2
    exit 66
fi
if [[ ! -f "${PROVENANCE_INPUT}" || -L "${PROVENANCE_INPUT}" ]]; then
    echo "ERROR: provenance must be a regular, non-symlink file: ${PROVENANCE_INPUT}" >&2
    exit 66
fi

ARCHIVE="$(realpath -e -- "${ARCHIVE_INPUT}")"
PROVENANCE="$(realpath -e -- "${PROVENANCE_INPUT}")"
WORKSPACE="$(realpath -m -- "${WORKSPACE_INPUT}")"
readonly ARCHIVE PROVENANCE WORKSPACE
readonly WORKSPACE_PARENT="${WORKSPACE%/*}"

if [[ "${WORKSPACE}" == "/" ]]; then
    echo "ERROR: workspace must not be the filesystem root" >&2
    exit 64
fi
if [[ ! -d "${WORKSPACE_PARENT}" || -L "${WORKSPACE_PARENT}" ]]; then
    echo "ERROR: workspace parent must be an existing, non-symlink directory: ${WORKSPACE_PARENT}" >&2
    exit 73
fi
if [[ -e "${WORKSPACE}" || -L "${WORKSPACE}" ]]; then
    echo "ERROR: refusing to replace an existing Work workspace: ${WORKSPACE}" >&2
    exit 73
fi

if [[ "$(grep -c '^format=work-source-provenance-v2$' "${PROVENANCE}")" != 1 ]] ||
    [[ "$(grep -c '^upstream_commit=[0-9a-f]\{40,64\}$' "${PROVENANCE}")" != 1 ]] ||
    [[ "$(grep -c '^upstream_tree=[0-9a-f]\{40,64\}$' "${PROVENANCE}")" != 1 ]] ||
    [[ "$(grep -c '^upstream_author_date=.' "${PROVENANCE}")" != 1 ]] ||
    [[ "$(grep -c '^archive_sha256=[0-9a-f]\{64\}$' "${PROVENANCE}")" != 1 ]] ||
    [[ "$(grep -c '^prepared_at_utc=.' "${PROVENANCE}")" != 1 ]] ||
    [[ "$(wc -l < "${PROVENANCE}")" != 6 ]]; then
    echo "ERROR: provenance format or field count is invalid" >&2
    exit 65
fi

UPSTREAM_COMMIT="$(sed -n 's/^upstream_commit=//p' "${PROVENANCE}")"
UPSTREAM_DATE="$(sed -n 's/^upstream_author_date=//p' "${PROVENANCE}")"
EXPECTED_SHA256="$(sed -n 's/^archive_sha256=//p' "${PROVENANCE}")"
ACTUAL_SHA256="$(sha256sum -- "${ARCHIVE}")"
ACTUAL_SHA256="${ACTUAL_SHA256%%[[:space:]]*}"
readonly UPSTREAM_COMMIT UPSTREAM_DATE EXPECTED_SHA256 ACTUAL_SHA256
if [[ "${ACTUAL_SHA256}" != "${EXPECTED_SHA256}" ]]; then
    echo "ERROR: archive SHA-256 does not match provenance" >&2
    exit 65
fi

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_COMMON_DIR
unset GIT_CONFIG_PARAMETERS GIT_DIR GIT_INDEX_FILE GIT_NAMESPACE
unset GIT_OBJECT_DIRECTORY GIT_WORK_TREE

STAGE=""
cleanup() { if [[ -n "${STAGE}" ]]; then rm -rf -- "${STAGE}"; fi; }
trap cleanup EXIT
STAGE="$(mktemp -d "${WORKSPACE_PARENT}/.initialize-work-workspace.XXXXXX")"

tar -xf "${ARCHIVE}" -C "${STAGE}" --no-same-owner --no-same-permissions
while IFS= read -r -d '' link; do
    link_target="$(readlink -- "${link}")"
    resolved_link="$(realpath -m -- "${link%/*}/${link_target}")"
    if [[ "${link_target}" == /* ]] ||
        [[ "${resolved_link}" != "${STAGE}" && "${resolved_link}" != "${STAGE}/"* ]]; then
        echo "ERROR: archive contains a symlink escaping the workspace: ${link#${STAGE}/}" >&2
        exit 65
    fi
done < <(find "${STAGE}" -type l -print0)

git -C "${STAGE}" init --quiet --initial-branch=work
git -C "${STAGE}" -c core.hooksPath=/dev/null add --all
GIT_AUTHOR_NAME='Work Source Preparation' \
GIT_AUTHOR_EMAIL='work-source@localhost' \
GIT_AUTHOR_DATE="${UPSTREAM_DATE}" \
GIT_COMMITTER_NAME='Work Source Preparation' \
GIT_COMMITTER_EMAIL='work-source@localhost' \
GIT_COMMITTER_DATE="${UPSTREAM_DATE}" \
    git -C "${STAGE}" -c core.hooksPath=/dev/null commit --quiet --allow-empty \
        -m "Baseline from upstream ${UPSTREAM_COMMIT}"

if [[ -n "$(git -C "${STAGE}" remote)" ]] ||
    [[ -n "$(git -C "${STAGE}" status --porcelain)" ]] ||
    [[ "$(git -C "${STAGE}" rev-list --count HEAD)" != 1 ]]; then
    echo "ERROR: initialized workspace failed baseline verification" >&2
    exit 70
fi
BASELINE_COMMIT="$(git -C "${STAGE}" rev-parse HEAD)"

if ! mv -T --no-clobber -- "${STAGE}" "${WORKSPACE}"; then
    echo "ERROR: workspace appeared during initialization; nothing was overwritten" >&2
    exit 73
fi
STAGE=""

echo "Work workspace initialized"
echo "  upstream commit: ${UPSTREAM_COMMIT}"
echo "  workspace:       ${WORKSPACE}"
echo "  baseline commit: ${BASELINE_COMMIT}"
