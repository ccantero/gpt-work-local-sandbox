#!/bin/bash
set -euo pipefail
umask 077

readonly HUMAN_USER="cristhian"
readonly WORK_USER="local-gpt-work"
readonly LIVE_WORKSPACE_ROOT="/home/local-gpt-work/workspaces"

usage() {
    echo "Usage: $0 [--non-interactive] [--ensure] [--check] <application-repository> <approved-commit> <workspace-name>" >&2
    exit 64
}

SUDO_FLAGS=()
ENSURE=false
CHECK=false
while (( $# > 0 )); do
    case "$1" in
        --non-interactive) SUDO_FLAGS=(-n); shift ;;
        --ensure) ENSURE=true; shift ;;
        --check) CHECK=true; shift ;;
        *) break ;;
    esac
done
if (( $# != 3 )); then usage; fi
readonly SOURCE_INPUT="$1"
readonly REVISION_INPUT="$2"
readonly WORKSPACE_NAME="$3"

for command in git tar mktemp mv rm find readlink realpath stat id sudo awk env; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "ERROR: required command is unavailable: ${command}" >&2
        exit 69
    fi
done

if [[ ! "${WORKSPACE_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] ||
    [[ "${WORKSPACE_NAME}" == "." || "${WORKSPACE_NAME}" == ".." ]]; then
    echo "ERROR: invalid workspace name: ${WORKSPACE_NAME}" >&2
    exit 64
fi

TESTING=false
TARGET_USER="${WORK_USER}"
WORKSPACE_ROOT="${LIVE_WORKSPACE_ROOT}"
if [[ "${PREPARE_WORK_TESTING:-}" == "1" ]]; then
    TESTING=true
    TARGET_USER="$(id -un)"
    WORKSPACE_ROOT="${PREPARE_WORK_TEST_ROOT:?ERROR: PREPARE_WORK_TEST_ROOT is required in test mode}"
    case "${WORKSPACE_ROOT}" in
        /tmp/*) ;;
        *) echo "ERROR: test workspace root must be beneath /tmp" >&2; exit 64 ;;
    esac
else
    RUN_AS="$(id -un)" || {
        echo "ERROR: could not determine execution identity" >&2
        exit 69
    }
    if [[ "${RUN_AS}" != "${HUMAN_USER}" ]]; then
        echo "ERROR: workspace preparation must be invoked by ${HUMAN_USER}" >&2
        exit 69
    fi
fi
readonly TESTING TARGET_USER WORKSPACE_ROOT

as_target() {
    if [[ "${TESTING}" == true ]]; then
        "$@"
    else
        sudo "${SUDO_FLAGS[@]}" -u "${TARGET_USER}" -- "$@"
    fi
}

if [[ ! -d "${SOURCE_INPUT}" ]]; then
    echo "ERROR: application repository is not a directory: ${SOURCE_INPUT}" >&2
    exit 66
fi
SOURCE="$(realpath -e -- "${SOURCE_INPUT}")"
readonly SOURCE

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_COMMON_DIR
unset GIT_CONFIG_PARAMETERS GIT_DIR GIT_INDEX_FILE GIT_NAMESPACE
unset GIT_OBJECT_DIRECTORY GIT_WORK_TREE

if ! git -C "${SOURCE}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: source is not a Git working tree: ${SOURCE}" >&2
    exit 65
fi
UPSTREAM_COMMIT="$(git -C "${SOURCE}" rev-parse --verify --end-of-options "${REVISION_INPUT}^{commit}")" || {
    echo "ERROR: revision does not resolve to a commit: ${REVISION_INPUT}" >&2
    exit 65
}
UPSTREAM_DATE="$(git -C "${SOURCE}" show -s --format='%aI' "${UPSTREAM_COMMIT}")"
readonly UPSTREAM_COMMIT UPSTREAM_DATE
if [[ "${ENSURE}" == true && "${REVISION_INPUT}" != "${UPSTREAM_COMMIT}" ]]; then
    echo "ERROR: unattended workspace preparation requires a full approved commit ID" >&2
    exit 65
fi

if git -C "${SOURCE}" ls-tree -r "${UPSTREAM_COMMIT}" |
    awk '$1 == "160000" { found=1 } END { exit !found }'; then
    echo "ERROR: approved commit contains gitlinks and is not self-contained" >&2
    exit 65
fi

if [[ ! -d "${WORKSPACE_ROOT}" || -L "${WORKSPACE_ROOT}" ]]; then
    echo "ERROR: workspace root must be an existing non-symlink directory: ${WORKSPACE_ROOT}" >&2
    exit 73
fi
WORKSPACE_ROOT_REAL="$(realpath -e -- "${WORKSPACE_ROOT}")"
if [[ "${TESTING}" != true && "${WORKSPACE_ROOT_REAL}" != "${LIVE_WORKSPACE_ROOT}" ]]; then
    echo "ERROR: unexpected workspace root: ${WORKSPACE_ROOT_REAL}" >&2
    exit 73
fi
readonly WORKSPACE_ROOT_REAL

TARGET_UID="$(id -u "${TARGET_USER}")"
ROOT_UID="$(stat -c '%u' -- "${WORKSPACE_ROOT_REAL}")"
readonly TARGET_UID ROOT_UID
if [[ "${ROOT_UID}" != "${TARGET_UID}" ]]; then
    echo "ERROR: workspace root must be owned by ${TARGET_USER}: ${WORKSPACE_ROOT_REAL}" >&2
    exit 73
fi

readonly WORKSPACE="${WORKSPACE_ROOT_REAL}/${WORKSPACE_NAME}"
WORKSPACE_STATE="$(as_target /bin/sh -c '
    if [ -L "$1" ]; then echo occupied
    elif [ -d "$1/.git" ] && [ ! -L "$1/.git" ]; then echo git
    elif [ -e "$1" ]; then echo occupied
    else echo absent
    fi
' sh "${WORKSPACE}")"
if [[ "${ENSURE}" == true && "${WORKSPACE_STATE}" == git ]]; then
    ROOT_COMMIT="$(as_target git -C "${WORKSPACE}" rev-list --max-parents=0 HEAD)"
    if [[ "${ROOT_COMMIT}" =~ ^[0-9a-f]{40,64}$ ]] &&
        [[ "$(as_target stat -c '%u' -- "${WORKSPACE}")" == "${TARGET_UID}" ]] &&
        [[ -z "$(as_target git -C "${WORKSPACE}" remote)" ]] &&
        [[ "$(as_target git -C "${WORKSPACE}" show -s --format=%B "${ROOT_COMMIT}" --)" == "Baseline from upstream ${UPSTREAM_COMMIT}" ]]; then
        echo "Existing Work workspace retained: ${WORKSPACE}"
        exit 0
    fi
fi
if [[ "${WORKSPACE_STATE}" != absent ]]; then
    echo "ERROR: refusing to replace existing workspace: ${WORKSPACE}" >&2
    exit 73
fi
if [[ "${CHECK}" == true ]]; then
    echo "Work workspace prerequisites verified: ${WORKSPACE}"
    exit 0
fi

STAGE=""
cleanup() {
    if [[ -n "${STAGE}" && ( -e "${STAGE}" || -L "${STAGE}" ) ]]; then
        as_target rm -rf -- "${STAGE}"
    fi
}
trap cleanup EXIT

STAGE="$(as_target mktemp -d "${WORKSPACE_ROOT_REAL}/.prepare-work-workspace.XXXXXX")"

git -C "${SOURCE}" archive --format=tar "${UPSTREAM_COMMIT}" |
    as_target tar -xf - -C "${STAGE}" --no-same-owner --no-same-permissions

while IFS= read -r -d '' link; do
    link_target="$(as_target readlink -- "${link}")"
    resolved_link="$(realpath -m -- "${link%/*}/${link_target}")"
    if [[ "${link_target}" == /* ]] ||
        [[ "${resolved_link}" != "${STAGE}" && "${resolved_link}" != "${STAGE}/"* ]]; then
        echo "ERROR: approved source contains an escaping symlink: ${link#${STAGE}/}" >&2
        exit 65
    fi
done < <(as_target find "${STAGE}" -type l -print0)

as_target git -C "${STAGE}" init --quiet --initial-branch=work
as_target git -C "${STAGE}" -c core.hooksPath=/dev/null add --all
as_target env \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_AUTHOR_NAME='Work Source Preparation' \
    GIT_AUTHOR_EMAIL='work-source@localhost' \
    GIT_AUTHOR_DATE="${UPSTREAM_DATE}" \
    GIT_COMMITTER_NAME='Work Source Preparation' \
    GIT_COMMITTER_EMAIL='work-source@localhost' \
    GIT_COMMITTER_DATE="${UPSTREAM_DATE}" \
    git -C "${STAGE}" -c core.hooksPath=/dev/null commit --quiet --allow-empty \
        -m "Baseline from upstream ${UPSTREAM_COMMIT}"

if [[ -n "$(as_target git -C "${STAGE}" remote)" ]] ||
    [[ -n "$(as_target git -C "${STAGE}" status --porcelain)" ]] ||
    [[ "$(as_target git -C "${STAGE}" rev-list --count HEAD)" != 1 ]]; then
    echo "ERROR: prepared workspace failed Git verification" >&2
    exit 70
fi

if ! as_target mv -T --no-clobber -- "${STAGE}" "${WORKSPACE}"; then
    echo "ERROR: workspace appeared during preparation; nothing was overwritten" >&2
    exit 73
fi
STAGE=""

WORKSPACE_UID="$(stat -c '%u' -- "${WORKSPACE}")"
if [[ "${WORKSPACE_UID}" != "${TARGET_UID}" ]]; then
    echo "ERROR: prepared workspace is not owned by ${TARGET_USER}" >&2
    exit 70
fi
BASELINE_COMMIT="$(as_target git -C "${WORKSPACE}" rev-parse HEAD)"

echo "Work workspace prepared"
echo "  upstream commit: ${UPSTREAM_COMMIT}"
echo "  workspace:       ${WORKSPACE}"
echo "  baseline commit: ${BASELINE_COMMIT}"
