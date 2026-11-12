# GPT Work local sandbox

Four primary scripts provide an isolated application workspace and disposable
PostgreSQL database for ChatGPT Work. The human-only `db_refresh` command
handles unattended BinanceBot dump and restore.

Workspace preparation accepts any approved, self-contained application Git
commit. The currently installed PostgreSQL helpers and their documented
database commands are the fixed, tested BinanceBot reference implementation;
the repository does not yet provide a generic multi-project database interface.

For approved dump acquisition, recovery, and the operational reference, see
[`RUNBOOK.md`](RUNBOOK.md).
Host installation and the persistent firewall lifecycle are in
[`SETUP.md`](SETUP.md); routine operation is in [`WORKFLOW.md`](WORKFLOW.md).

## Security contract

- `cristhian` selects approved application commits, prepares workspaces, and
  launches Work.
- `local-gpt-work` owns its workspaces and may modify `binancebot_work`.
- Work cannot access the human-owned application repository.
- `binancebot_work_baseline` is protected and PostgreSQL-administered.
- Work may invoke only the installed, fixed, no-argument reset helper as
  `postgres`; baseline refresh remains human-only and separate.
- Approved dumps stay human-controlled and outside Work.
- Repository helper source is never elevated. Privileged execution uses
  independently reviewed copies under `/usr/local/sbin`.
- Preparation and launch run only from a human-controlled checkout, never a
  Work-writable copy.

This is a PostgreSQL/filesystem boundary, not VM-grade isolation. Shared X11
also limits OS-account isolation.

## Accepted risk: shared X11 display

| Field | Value |
| --- | --- |
| Risk ID | `RISK-X11-001` |
| Title | Shared X11 display between `cristhian` and `local-gpt-work` |
| Severity | Low (within the current operational threat model) |
| Status | Accepted |
| Owner | Human project administrator |

`run-work.sh` allows ChatGPT Work, running as `local-gpt-work`, to use the
graphical X11 session of `cristhian`. X11 does not provide strong isolation
between authorized clients sharing a display. A process running as
`local-gpt-work` with access to that display may potentially observe or
interact with other graphical applications in the human session.

The human project administrator accepts this risk because:

1. the project prioritizes a low-friction graphical ChatGPT Work experience;
2. the sandbox is designed primarily to contain accidental development and
   operational errors, not deliberately hostile code;
3. the filesystem, Git, PostgreSQL, sudo, and network restrictions remain
   separate controls; and
4. a separate graphical server would add complexity and could undermine the
   intended user experience.

This acceptance does not establish VM-grade isolation or make arbitrary
untrusted code safe. Revisit the decision if the threat model expands to
include malicious agents or untrusted executable code, sensitive graphical
applications are routinely exposed during Work sessions, a practical
alternative provides stronger graphical isolation without materially degrading
the workflow, or a relevant security incident occurs.

## Four primary scripts

| Responsibility | Repository source | Operational use | Actor |
| --- | --- | --- | --- |
| Refresh baseline | `refresh_baseline.sh` | `/usr/local/sbin/refresh-binancebot-baseline` | Human administrator as `postgres` |
| Reset Work DB | `reset-binancebot-work` | `/usr/local/sbin/reset-binancebot-work` | Work via exact no-argument sudo |
| Prepare workspace | `prepare-work-workspace.sh` | Human-controlled checkout | `cristhian` |
| Launch Work | `run-work.sh` | Human-controlled checkout | `cristhian` |

`prepare-codex-env` runs from the human-controlled checkout and uses the
installed PostgreSQL helpers. Only an explicit `--refresh` contacts the
configured `vpsdatabase` service. The human keeps verified snapshots and
their checksums in private storage outside Git and Work. Launch Work
separately with `run-work.sh` from the human graphical session.
See [SETUP.md](SETUP.md) for installation and [WORKFLOW.md](WORKFLOW.md) for
daily commands.

## Prepare a workspace

`/home/local-gpt-work/workspaces` must already exist, be owned by
`local-gpt-work`, and not be a symlink. From this human-controlled checkout:

```bash
./prepare-work-workspace.sh \
  /absolute/path/to/human-owned/application-repository \
  <full-approved-commit-id> \
  <workspace-name>
```

The script must be invoked by `cristhian`. It resolves the commit, rejects
gitlinks, streams `git archive` directly into a temporary directory created
as `local-gpt-work`, rejects escaping symlinks, and atomically publishes:

```text
/home/local-gpt-work/workspaces/<workspace-name>
```

The result is Work-owned, clean, has one independent baseline commit, and no
remote. Only tracked files from the approved commit cross the boundary—never
the human `.git`, remotes, ignored/untracked files, credentials, local
configuration, or a persistent archive. Existing workspaces are not replaced.

`PREPARE_WORK_TESTING=1` is restricted to roots below `/tmp`; it exists only
for non-privileged automated tests and does not validate live sudo behavior.

## Routine operation

As `local-gpt-work`, reset the disposable database:

```bash
sudo -u postgres /usr/local/sbin/reset-binancebot-work
```

The installed helper accepts no arguments, uses fixed connection and database
values, verifies baseline protection, and recreates only `binancebot_work`.
Reset is destructive and may leave Work absent if recreation fails.

From `cristhian`'s graphical session and this human-controlled checkout:

```bash
PROD_VPS_IP='<production-vps-ipv4>' ./run-work.sh
```

Then select the prepared workspace in ChatGPT Work. The launcher ensures the
owner/IP OUTPUT reject before granting X11 access, switches user, starts
ChatGPT, and removes only a rule it added during normal cleanup.

The rule covers only the supplied IPv4. It does not cover alternate addresses,
IPv6, aliases, proxies, or other routes; concurrent launchers can race over
rule lifetime.

## Persistent UFW Work network policy

`configure-work-ufw-policy.sh` is reviewable source for a separately installed,
root-owned administrator helper. It manages a marked block in UFW's
`before.rules` (and, when approved IPv6 destinations are supplied,
`before6.rules`). The hook is placed before UFW's
`RELATED,ESTABLISHED` accept rule, so an existing connection from
`local-gpt-work` cannot bypass the destination reject. It resolves the user's
numeric UID at installation time, owns only its marked block, is idempotent,
and reloads UFW only when executed from its protected installed path by root.
It requires both matching `iptables-restore --test` utilities before a live
file replacement and serializes changes with a lock in the UFW configuration
directory. It verifies UID, GID, mode, and modification time. ACLs, extended
attributes, and security labels require independent review. It
retains rollback copies through reload and restores each file through a
same-directory staged atomic replacement if replacement or reload fails. A
failed restoration, rollback reload, or interruption after reload begins
retains and reports rollback-copy paths; effective kernel state remains a
human-administrator recovery concern.

The policy rejects outbound traffic only when both the Work UID and an
administrator-supplied destination match. It does not change UFW defaults or
allow rules, so general Internet access remains governed by the existing UFW
policy. It must be installed, validated, and explicitly accepted by the human
administrator before any future, separate proposal to simplify `run-work.sh`.
The launcher’s temporary IPv4 protection remains in place in this change.

The repository supplies fixture tests only. It has not inspected the live UFW,
iptables-nft, libvirt, or reboot behavior; see `SETUP.md` for mandatory
human-controlled validation and rollback.

## Occasional baseline refresh

The human-only `db_refresh` entry point provides a database-only workflow
using the same installed refresh and reset helpers. See the
[database runbook](RUNBOOK.md#unattended-postgresql-dump-and-restore).

Use [the human refresh workflow](WORKFLOW.md#prepare-the-binancebot-environment)
for a new or previously approved archive. The protected installed helper
validates the candidate before promoting it in a transaction. It retains the
old baseline until the separate reset helper recreates Work and validation
passes. Recovery uses the archive's checksum and PostgreSQL comments to
identify work from an interrupted refresh. See
[the runbook](RUNBOOK.md#unattended-binancebot-preparation) for recovery cases.

Never elevate `refresh_baseline.sh` from this repository.

## Protected installation

Installed helpers and controlling parent directories must be unwritable by
`local-gpt-work`. A human separately reviews and installs exact bytes and
verifies ownership, modes, ACLs, and sudo policy.

The only intended Work sudo command is exact, no-argument execution of
`/usr/local/sbin/reset-binancebot-work`. Do not authorize refresh, PostgreSQL
clients, shells, interpreters, editors, argument-bearing reset, or selectable
database targets.

Fixed reference values are `local-gpt-work`, `binancebot_work`,
`binancebot_work_baseline*`, PostgreSQL 17 binaries, socket
`/var/run/postgresql`, and port `5432`. Changing them is a separate reviewed
host migration.

## Tests and E2E prerequisites

Non-destructive tests:

```bash
tests/test-prepare-work-workspace.sh
tests/test-run-work.sh
python3 tests/test-prepare-codex-env.py
tests/test-refresh-baseline.sh
tests/test-configure-work-ufw-policy.sh
tests/test-configure-work-ufw-docker-config.sh
```

The preparation, launcher and firewall-policy tests use fixtures under `/tmp`.
The refresh integration test starts an unprivileged PostgreSQL 17 fixture
with a private Unix socket and synthetic data. It requires permission to bind
that socket. These tests leave the installed helpers and host firewall alone.

The optional Docker integration harness, `tests/test-configure-work-ufw-docker.sh`,
uses a build context containing only the helper and Dockerfile. It uses
unique, internal disposable networks, a
UFW container with NET_ADMIN (never privileged or host networking), and
controlled HTTP targets. It proves target readiness before policy installation,
checks installed rules and packet counters after rejection, and compares
normalized Work-policy rules for idempotency. It runs actual IPv4 and IPv6
block/permitted/removal checks. It exits with status 2 and an UNSUPPORTED
message if Docker, the daemon, or isolated IPv6 networking is unavailable;
that is not a passing integration result.

Ubuntu UFW uses ufw-before-output for IPv4 and ufw6-before-output for IPv6.
The persistent-policy installer validates and hooks each family-specific chain
before its RELATED,ESTABLISHED accept rule.

Its IPv6 network uses the explicit ULA subnet fd42:4757:2026:1::/64 by
default, avoiding Docker automatic IPv6-pool allocation. Override it only with
another non-overlapping ULA /64 through DOCKER_UFW_IPV6_SUBNET. The harness
validates the value and checks existing Docker network subnets before creating
its run-unique IPv6 network.

The IPv6 portion reports four explicit phases: connectivity before UFW is
enabled, connectivity after UFW but before the custom policy, custom-policy
blocking, and post-removal restoration. A baseline failure stops before policy
installation and emits container addresses, listener state, routes, proxy
variable names, UFW status, ip6tables counters, and root/Work curl diagnostics.

Before live E2E, a human must verify:

- the live workspace root exists, is not a symlink, and is Work-owned;
- the selected application commit is approved and self-contained;
- existing user-switch authorization is sufficient for preparation;
- installed helpers still match reviewed sources and remain protected;
- the exact reset-only Work sudo boundary still holds; and
- the supplied production VPS IPv4 is current.

Keep database dumps, snapshot metadata, schema experiments, table inventories,
and source archives outside this repository.
