#!/bin/bash
set -euo pipefail
umask 077

readonly ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly PREPARE="${ROOT}/prepare-work-workspace.sh"
FIXTURE="$(mktemp -d)"
cleanup() { rm -rf -- "${FIXTURE}"; }
trap cleanup EXIT

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

source_repo="${FIXTURE}/human-project"
workspaces="${FIXTURE}/workspaces"
mkdir -p -- "${source_repo}" "${workspaces}"
git -C "${source_repo}" init --quiet --initial-branch=main
printf 'tracked\n' > "${source_repo}/tracked.txt"
printf 'ignored.env\n' > "${source_repo}/.gitignore"
git -C "${source_repo}" add tracked.txt .gitignore
GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost GIT_AUTHOR_DATE='2026-01-02T03:04:05Z' \
GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost GIT_COMMITTER_DATE='2026-01-02T03:04:05Z' \
    git -C "${source_repo}" commit --quiet -m fixture
upstream_commit="$(git -C "${source_repo}" rev-parse HEAD)"
printf 'untracked secret\n' > "${source_repo}/untracked.txt"
printf 'secret\n' > "${source_repo}/ignored.env"
git -C "${source_repo}" remote add origin https://example.invalid/private/repository.git

run_prepare() {
    PREPARE_WORK_TESTING=1 PREPARE_WORK_TEST_ROOT="${workspaces}" \
        "${PREPARE}" "$@"
}

run_prepare "${source_repo}" "${upstream_commit}" project >/dev/null
workspace="${workspaces}/project"
test -f "${workspace}/tracked.txt"
test ! -e "${workspace}/untracked.txt"
test ! -e "${workspace}/ignored.env"
test -d "${workspace}/.git"
test -z "$(git -C "${workspace}" remote)"
test -z "$(git -C "${workspace}" status --porcelain)"
test "$(git -C "${workspace}" rev-list --count HEAD)" = 1
test "$(stat -c '%u' "${workspace}")" = "$(id -u)"
git -C "${workspace}" log -1 --format=%s |
    grep -qx "Baseline from upstream ${upstream_commit}"

printf 'work change\n' >> "${workspace}/tracked.txt"
if run_prepare "${source_repo}" "${upstream_commit}" project >/dev/null 2>&1; then
    echo "FAIL: existing workspace was overwritten" >&2
    exit 1
fi
grep -qx 'work change' <(tail -n 1 "${workspace}/tracked.txt")
run_prepare --ensure --non-interactive --check "${source_repo}" "${upstream_commit}" project >/dev/null
run_prepare --ensure --non-interactive "${source_repo}" "${upstream_commit}" project >/dev/null
grep -qx 'work change' <(tail -n 1 "${workspace}/tracked.txt")

if run_prepare "${source_repo}" "${upstream_commit}" '../escape' >/dev/null 2>&1; then
    echo "FAIL: invalid workspace name was accepted" >&2
    exit 1
fi

if PREPARE_WORK_TESTING=1 PREPARE_WORK_TEST_ROOT="/var/tmp/not-allowed" \
    "${PREPARE}" "${source_repo}" "${upstream_commit}" elsewhere >/dev/null 2>&1; then
    echo "FAIL: non-/tmp test root was accepted" >&2
    exit 1
fi

escape_repo="${FIXTURE}/escape-project"
mkdir -- "${escape_repo}"
git -C "${escape_repo}" init --quiet --initial-branch=main
ln -s ../../outside-secret "${escape_repo}/escape"
git -C "${escape_repo}" add escape
GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost GIT_AUTHOR_DATE='2026-01-02T03:04:05Z' \
GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost GIT_COMMITTER_DATE='2026-01-02T03:04:05Z' \
    git -C "${escape_repo}" commit --quiet -m escape
if run_prepare "${escape_repo}" HEAD escaping >/dev/null 2>&1; then
    echo "FAIL: escaping symlink was accepted" >&2
    exit 1
fi
test ! -e "${workspaces}/escaping"

gitlink_repo="${FIXTURE}/gitlink-project"
mkdir -- "${gitlink_repo}"
git -C "${gitlink_repo}" init --quiet --initial-branch=main
git -C "${gitlink_repo}" update-index --add --cacheinfo \
    160000,"${upstream_commit}",dependency
GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost GIT_AUTHOR_DATE='2026-01-02T03:04:05Z' \
GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost GIT_COMMITTER_DATE='2026-01-02T03:04:05Z' \
    git -C "${gitlink_repo}" commit --quiet -m gitlink
if run_prepare "${gitlink_repo}" HEAD gitlink >/dev/null 2>&1; then
    echo "FAIL: gitlink was accepted" >&2
    exit 1
fi

grep -Fq 'readonly LIVE_WORKSPACE_ROOT="/home/local-gpt-work/workspaces"' "${PREPARE}"
grep -Fq 'sudo "${SUDO_FLAGS[@]}" -u "${TARGET_USER}" -- "$@"' "${PREPARE}"
grep -Fq 'workspace preparation must be invoked by ${HUMAN_USER}' "${PREPARE}"

echo "All workspace preparation tests passed"
