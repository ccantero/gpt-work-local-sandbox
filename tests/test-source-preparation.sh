#!/bin/bash
set -euo pipefail
umask 077

readonly ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly PREPARE="${ROOT}/prepare-work-source.sh"
readonly INITIALIZE="${ROOT}/initialize-work-workspace.sh"
FIXTURE="$(mktemp -d)"
cleanup() { rm -rf -- "${FIXTURE}"; }
trap cleanup EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

source_repo="${FIXTURE}/human-project"
handoff="${FIXTURE}/handoff"
workspaces="${FIXTURE}/workspaces"
mkdir -p -- "${source_repo}" "${handoff}" "${workspaces}"
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

archive="${handoff}/project.tar"
provenance="${handoff}/project.provenance"
"${PREPARE}" "${source_repo}" "${upstream_commit}" "${archive}" "${provenance}" >/dev/null
test -f "${archive}"
test -f "${provenance}"
test ! -e "${workspaces}/project"
test "$(stat -c '%a' "${archive}")" = 444
test "$(stat -c '%a' "${provenance}")" = 444
grep -qx "upstream_commit=${upstream_commit}" "${provenance}"

second_archive="${handoff}/project-second.tar"
second_provenance="${handoff}/project-second.provenance"
"${PREPARE}" "${source_repo}" "${upstream_commit}" "${second_archive}" "${second_provenance}" >/dev/null
test "$(sha256sum "${archive}" | sed 's/[[:space:]].*//')" = \
    "$(sha256sum "${second_archive}" | sed 's/[[:space:]].*//')"

if "${PREPARE}" "${source_repo}" HEAD "${archive}" "${provenance}" >/dev/null 2>&1; then
    echo "FAIL: existing handoff artifacts were overwritten" >&2
    exit 1
fi

workspace="${workspaces}/project"
"${INITIALIZE}" "${archive}" "${provenance}" "${workspace}" >/dev/null
test -f "${workspace}/tracked.txt"
test ! -e "${workspace}/untracked.txt"
test ! -e "${workspace}/ignored.env"
test -d "${workspace}/.git"
test -z "$(git -C "${workspace}" remote)"
test -z "$(git -C "${workspace}" status --porcelain)"
test "$(git -C "${workspace}" rev-list --count HEAD)" = 1

second_workspace="${workspaces}/project-second"
"${INITIALIZE}" "${second_archive}" "${second_provenance}" "${second_workspace}" >/dev/null
test "$(git -C "${workspace}" rev-parse HEAD)" = \
    "$(git -C "${second_workspace}" rev-parse HEAD)"

printf 'work change\n' >> "${workspace}/tracked.txt"
if "${INITIALIZE}" "${archive}" "${provenance}" "${workspace}" >/dev/null 2>&1; then
    echo "FAIL: existing workspace was overwritten" >&2
    exit 1
fi
grep -qx 'work change' <(tail -n 1 "${workspace}/tracked.txt")

chmod 0644 "${archive}"
printf 'tamper' >> "${archive}"
if "${INITIALIZE}" "${archive}" "${provenance}" "${workspaces}/tampered" >/dev/null 2>&1; then
    echo "FAIL: archive hash mismatch was accepted" >&2
    exit 1
fi
test ! -e "${workspaces}/tampered"

escape_repo="${FIXTURE}/escape-project"
mkdir -- "${escape_repo}"
git -C "${escape_repo}" init --quiet --initial-branch=main
ln -s ../../outside-secret "${escape_repo}/escape"
git -C "${escape_repo}" add escape
GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost GIT_AUTHOR_DATE='2026-01-02T03:04:05Z' \
GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost GIT_COMMITTER_DATE='2026-01-02T03:04:05Z' \
    git -C "${escape_repo}" commit --quiet -m escape
if "${PREPARE}" "${escape_repo}" HEAD "${handoff}/escape.tar" "${handoff}/escape.provenance" >/dev/null 2>&1; then
    echo "FAIL: escaping symlink was accepted" >&2
    exit 1
fi

echo "All source preparation tests passed"
