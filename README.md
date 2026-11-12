# GPT Work PostgreSQL sandbox

This repository contains reviewable source and operating guidance for running
ChatGPT Work under a restricted Linux account with a local PostgreSQL
development sandbox. The architecture is reusable: application source arrives
through an approved, credential-free handoff; the application workspace and
development database are disposable; and human-owned repositories,
credentials, privileged host configuration, and baseline resources remain
protected.

## Architecture contract

The protected baseline and disposable Work database deliberately belong to
different trust domains.

| Generic resource | Owner | Contract |
| --- | --- | --- |
| protected baseline database | PostgreSQL administrator | The restricted Work account must not be able to connect, create in it, replace it, refresh it, rename it, drop it, or administer it. |
| disposable Work database | restricted Work role | Work may freely use, modify, or destroy it. It can be recreated from the protected baseline. |

Baseline refresh may temporarily use protected candidate and previous-baseline
databases. They are administrator-owned recovery state, not additional
development databases.

The two administrative operations are deliberately separate:

- **Baseline refresh** is an occasional operation initiated by the human
  administrator.
  It replaces the protected baseline from an approved production-derived dump
  through the candidate/promotion workflow. `local-gpt-work` is not authorized
  to perform it.
- **Work reset** is a routine operation available to the restricted Work
  account. It drops and recreates only the disposable Work database from the
  protected baseline.

These operations must never be combined. Access to work reset must expose no
path that can refresh, replace, drop, rename, or otherwise administer the
baseline.

## Reference implementation values

The reusable architecture does not require the names used on the host where it
was developed. The current privileged helper sources are a fixed-purpose
reference implementation and still pin these installation values:

- restricted account and database owner: `local-gpt-work`;
- disposable database: `binancebot_work`;
- protected database family: `binancebot_work_baseline*`; and
- installed commands: `/usr/local/sbin/reset-binancebot-work` and
  `/usr/local/sbin/refresh-binancebot-baseline`.

Occurrences of those values in commands below describe that validated
installation. Adapting the helpers for another application or host is a
separate, reviewed migration; do not make privileged reset targets selectable
at runtime.

## Source and installed commands

Repository files are editable source for review and testing. They are never the
privileged executables:

| Repository source | Protected installed command | Authorized actor |
| --- | --- | --- |
| `refresh_baseline.sh` | `/usr/local/sbin/refresh-binancebot-baseline` | human administrator, manually as the `postgres` OS user |
| `reset-binancebot-work` | `/usr/local/sbin/reset-binancebot-work` | `local-gpt-work`, exactly as the `postgres` OS user with no arguments |

Both installed files and every controlling parent directory must be protected
from modification by `local-gpt-work`. Editing repository source must never
implicitly update either installed command. A human separately reviews and
installs the desired bytes, then verifies ownership, mode, parent-directory
permissions, and source/installed SHA-256 digests.

The intended sudo boundary for the development account is only exact,
no-argument execution of `/usr/local/sbin/reset-binancebot-work` as the
`postgres` OS user. The local sudo implementation's syntax must enforce zero
arguments, and the helper independently rejects arguments. Do not grant
`local-gpt-work` access to refresh, PostgreSQL clients, a shell, an interpreter,
an editor, or an argument-bearing reset variant.

## Fixed endpoint and verified state

Administrative sources pin PostgreSQL 17 at socket `/var/run/postgresql`, port
`5432`, and database role `postgres`. They clear connection-related `PG*` state
so a caller cannot redirect privileged operations.

These installation facts were human-verified on the reference host:

- PostgreSQL server version is 17.10;
- both databases use `pg_default` and are approximately 21 GB;
- work is owned by `local-gpt-work`, which has `CONNECT` and `CREATE` there;
- baseline is owned by `postgres`, and `local-gpt-work` has neither `CONNECT`
  nor `CREATE` there;
- `local-gpt-work` has `LOGIN`, but not `SUPERUSER`, `CREATEDB`, `CREATEROLE`,
  `REPLICATION`, or `BYPASSRLS`;
- `local-gpt-work` has no inherited role memberships; and
- no candidate or previous database was present when these facts were checked.

Baseline application objects are owned by `local-gpt-work`, allowing a
physical `file_copy` clone to remain usable by the application role. Database
ownership and access restrictions, not application-object ownership, protect
the baseline.

This is a PostgreSQL and filesystem boundary, not general operating-system
isolation. Use a VM or container when stronger process isolation is required.

## Infrastructure and application source

`gpt-work-local-sandbox` is infrastructure, not the application repository
that Work normally modifies. The infrastructure repository is public. A
restricted runtime may clone and pull reviewed infrastructure commits over
public HTTPS without an SSH key, token, or other GitHub credentials.

This is a narrow control-plane exception. Application repositories use a
different path: the human operator exports an approved commit as tracked
source plus provenance, transfers that pair to the restricted account, and
initializes a disposable workspace with independent one-commit Git history and
no remote. The restricted account receives neither normal GitHub access nor
human credentials for application repositories. See `WORKFLOW.md`.

The isolated user intentionally owns and controls its `repos/` and
`workspaces/` directories. Their contents are disposable workflow state, not a
security boundary. The protected boundaries remain the human repositories and
credentials, production credentials and dumps, PostgreSQL baseline, installed
privileged helpers, host configuration, and narrow sudo policy.

Work may edit and test freely in an application workspace, make one or more
local commits, and generate review material. Those commits belong to Work's
independent repository history: their hashes are not revisions the human can
use in the original application repository. The supported return path is a
patch representing the complete change from the Work baseline to Work's final
`HEAD`, accompanied by a self-contained implementation report. The human
verifies and applies the patch, reviews and tests the resulting change, and
then decides whether to commit or publish it from the human-owned repository.
Shared Git access to a Work workspace is neither required nor supported; do
not change workspace ownership or add `safe.directory` merely to make that
repository usable by the human account.

## Validated application round trip

The complete application workflow has been validated end to end: approved
source was handed off, verified, and initialized as an isolated repository;
Work implemented and tested a change without a remote or GitHub credentials;
and the human verified, applied, reviewed, and tested the resulting patch in
the original repository before independently committing it.

The stable return location prepared for future runs is
`/home/local-gpt-work/deliverables`, owned by `local-gpt-work` with mode `0755`.
It was prepared after the successful validation and has not yet been validated
as part of a subsequent round trip. Review artifacts should remain outside the
application Git repository so they cannot accidentally enter application
commits.

## Routine development and work reset

From a terminal in the human Linux user's existing graphical session, provide
the production VPS IPv4 address through the environment and start the launcher:

```bash
PROD_VPS_IP='<production-vps-ip>' ./run-work.sh
```

The address is an operator-supplied host value and must not be committed. The
launcher grants `local-gpt-work` access to the human's X display, obtains that
account's UID, and ensures an owner-matched `iptables` reject rule exists for
the supplied address. It then switches to `local-gpt-work`, supplies that
account's runtime and D-Bus paths, and starts `/usr/bin/chatgpt` in X11 mode.
On exit or a handled signal it removes the graphical grant and removes the
firewall rule only when this invocation added it. Workspace selection remains
an explicit step in ChatGPT Work.

This launcher intentionally preserves the already working host behavior. Its
logging, sudo prompt handling, firewall lifecycle, and process shutdown
behavior are known follow-up improvements and are not redesigned here.

Connect only to the disposable work database:

```bash
psql -h /var/run/postgresql -p 5432 -d binancebot_work
```

When a clean copy is needed, the intended installed invocation is:

```bash
sudo -u postgres /usr/local/sbin/reset-binancebot-work
```

The installed reset helper accepts no arguments and contains fixed database
names, endpoint, administrator, and owner. Before destructive work begins, it
uses that fixed endpoint and administrator identity to verify that baseline
exists; a failed check or missing baseline aborts without modifying work. It may
drop/recreate only work and reads baseline only as the fixed clone source. Reset
is destructive to work and may terminate work connections. It has no refresh
mode and no baseline mutation command.

## Database refresh

The human operator runs `./db_refresh --full` to acquire and restore a fresh
approved snapshot, or `./db_refresh --restore-only` to retry with a verified
local archive. The tool stores snapshots and checksums in private storage
outside Git and Work. See the [database runbook](RUNBOOK.md) for commands,
detached execution, and recovery. Launch Work separately with `run-work.sh`.

The reviewed installed helper restores a protected candidate under
`local-gpt-work` while ignoring archive owners and ACLs. It promotes the
validated candidate transactionally, keeps the previous baseline through Work
reset and verification, and uses checksum markers to recover interrupted
runs. The validation checks PostgreSQL ownership, privileges, and application
relation presence. Application acceptance remains an operator responsibility.

## Human-only installation and configuration

Repository implementation does not change the host. An authorized human must:

1. review the exact refresh and reset source versions and record their SHA-256
   digests;
2. install them separately at the protected paths above without executing
   repository files with privilege;
3. compare installed digests with reviewed digests and verify `/usr/local`,
   `/usr/local/sbin`, and both files are not writable by `local-gpt-work`
   through owner, group, mode, or ACL;
4. configure and validate a sudoers rule permitting `local-gpt-work` only the
   exact no-argument reset invocation as `postgres`; and
5. use `sudo -l -U local-gpt-work` to confirm refresh and broader commands are
   absent before any destructive acceptance test.

Changing source later does not change or invalidate an intentionally installed
version. Installation is a separate reviewed human action.

## Read-only verification

As `local-gpt-work`, confirm the role and work connection, then baseline denial:

```bash
psql -h /var/run/postgresql -p 5432 -d binancebot_work -Atqc \
  "SELECT rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls FROM pg_roles WHERE rolname=current_user;"
# expected: f|f|f|f|f

psql -h /var/run/postgresql -p 5432 -d binancebot_work -Atqc \
  'SELECT current_database(), current_user;'
# expected: binancebot_work|local-gpt-work

psql -h /var/run/postgresql -p 5432 -d binancebot_work_baseline -c 'SELECT 1;'
# expected: permission denied
```

An authorized administrator should also verify database ownership, effective
`CONNECT`/`CREATE`, role memberships, installed file/parent permissions,
installed digests, and exact sudo policy. Candidate and previous, when present,
must have the same protected access posture as baseline.

## Repository contents

- `WORKFLOW.md`: human-to-Work source preparation and review workflow.
- `run-work.sh`: human-session launcher that grants graphical access, manages
  the scoped firewall rule, switches to `local-gpt-work`, and starts ChatGPT.
- `prepare-work-source.sh`: human-side deterministic tracked-source handoff
  creation.
- `initialize-work-workspace.sh`: isolated-user handoff verification and
  independent Work repository creation.
- `refresh_baseline.sh`: source for protected baseline refresh.
- `reset-binancebot-work`: source for narrow work reset.
- `db_refresh`: human-only unattended snapshot acquisition and restore.
- `prepare-codex-env`: database workflow support and optional workspace preparation.
- `prepare-work-workspace.sh`: direct preparation from an approved Git commit.

Run the non-privileged database workflow tests with
`python3 tests/test-prepare-codex-env.py`. Run `tests/test-refresh-baseline.sh`
for a disposable PostgreSQL 17 fixture that needs a private Unix socket.
