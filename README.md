# GPT Work PostgreSQL sandbox

This repository documents and supports a small local isolation boundary for
Codex/ChatGPT Work. The agent can freely change one disposable PostgreSQL
database without being able to change the protected baseline or administer the
PostgreSQL cluster.

## Architecture

| Resource | Owner | Purpose |
| --- | --- | --- |
| `binancebot_work` | `local-gpt-work` | Disposable database used for development, tests, and migrations. |
| `binancebot_work_baseline` | `postgres` | Protected, known-good source for rebuilding the work database. |
| `binancebot_work_baseline_candidate` | `postgres` | Temporary staging database used during a baseline refresh. |
| `binancebot_work_baseline_previous` | `postgres` | Temporary rollback copy retained while a promoted baseline and rebuilt work database are verified. |
| `/usr/local/sbin/reset-binancebot-work` | system-managed | Privileged, narrowly scoped reset command. It is not maintained or modified by the restricted user. |

The reset command recreates `binancebot_work` from
`binancebot_work_baseline` with PostgreSQL's `file_copy` strategy. A baseline
refresh uses a candidate-and-promote sequence so that the existing baseline is
not replaced until a restored candidate has passed validation.

```text
trusted custom-format dump
          |
          v
baseline_candidate --validate/protect--> baseline
                                           |
                                           | file_copy
                                           v
                                    binancebot_work
```

## Security model

The Linux and PostgreSQL role `local-gpt-work` may connect to, own, and freely
modify `binancebot_work`. It is expected to be able to destroy data and schema
objects there.

The role must not:

- connect to `binancebot_work_baseline` (or the candidate/previous databases),
- create arbitrary databases,
- create roles or become a PostgreSQL superuser,
- modify the installed reset command, or
- access production credentials or the administrator's files.

The baseline database itself is owned by `postgres`; application objects
restored into it are owned by `local-gpt-work`. This lets a `file_copy` clone
produce a work database whose application objects remain usable by the
restricted role, while database-level `CONNECT` protection keeps the baseline
out of reach.

This is a database and filesystem boundary, not a disposable operating system.
It does not replace a VM or container when stronger process isolation is
required.

## Normal workflow

Connect only to the work database:

```bash
psql -d binancebot_work
```

Run application migrations, tests, and ad hoc data changes there. When a clean
copy is needed, an authorized administrator can run:

```bash
sudo /usr/local/sbin/reset-binancebot-work
```

Resetting drops and recreates `binancebot_work`; all unexported work-database
changes are lost. The command may also fail if other sessions are connected, so
stop applications and interactive `psql` sessions first.

The repository's `reset-binancebot-work` file records the expected reset
implementation. The installed `/usr/local/sbin/reset-binancebot-work` is the
privileged copy used in practice and must not be writable by `local-gpt-work`.

## Dumps and snapshots

`do_snapshot.sh <postgres-service>` creates a timestamped custom-format dump in
`snapshots/`. Treat dumps as sensitive: they can contain production data and
must not be committed. `.gitignore` excludes the entire `snapshots/` directory
and common PostgreSQL dump suffixes (`.dump`, `.backup`, and `.sql`, including
compressed variants).

Before using a dump, confirm that it came from a trusted source. Restoring a
dump executes its schema definitions as the application role.

## Refreshing the protected baseline

Baseline refresh is an administrative operation. It changes PostgreSQL state,
rebuilds the work database, and requires `sudo`; do not run it from an automated
agent session. Stop connections to the work and baseline databases, then run
the script as the authorized human administrator:

```bash
./refresh_baseline.sh snapshots/<trusted-snapshot>.dump
```

The script:

1. validates that the input is a PostgreSQL custom-format archive and records
   its SHA-256 digest;
2. checks that the baseline exists and that no stale candidate or previous
   database would be overwritten;
3. checks free space, creates a candidate with a zero connection limit, revokes
   public access, and restores as `local-gpt-work`;
4. records a completed-restore marker containing the dump digest, validates
   application object ownership, and removes temporary create privileges;
5. renames the old baseline to `binancebot_work_baseline_previous` and promotes
   the candidate;
6. validates the promoted baseline, invokes the installed reset command, and
   validates the rebuilt work database; and
7. removes the previous baseline only after all validation succeeds.

The free-space check is deliberately conservative but is based on the current
baseline size. Check capacity manually when the incoming dump is expected to
expand substantially.

### Resuming after an interruption

Use `--resume` only when the restore completed successfully and a later step
failed while the database was still named
`binancebot_work_baseline_candidate`:

```bash
./refresh_baseline.sh --resume snapshots/<same-trusted-snapshot>.dump
```

Resume mode does not restore again. It hashes the supplied dump and requires the
candidate's completed-restore marker to contain the same digest. It then repeats
candidate validation and continues with protection and promotion.

Do not use `--resume` after `pg_restore` failed, with a different dump, or after
the candidate has already been promoted. A failed/partial restore has no
completed-restore marker and is intentionally rejected.

## Verification

Run these read-only checks in the appropriate account after setup, reset, or
refresh.

As `local-gpt-work`, confirm the role is neither a superuser nor allowed to
create databases:

```bash
psql -d binancebot_work -Atqc \
  "SELECT rolsuper, rolcreatedb FROM pg_roles WHERE rolname = current_user;"
# expected: f|f
```

Confirm the work database is usable and the baseline rejects a connection:

```bash
psql -d binancebot_work -Atqc \
  "SELECT current_database(), current_user;"
# expected: binancebot_work|local-gpt-work

psql -d binancebot_work_baseline -c 'SELECT 1;'
# expected: permission denied for database binancebot_work_baseline
```

As an authorized administrator, inspect ownership and effective access:

```bash
sudo -u postgres psql -d postgres -P pager=off -x -c "
SELECT datname,
       pg_get_userbyid(datdba) AS owner,
       datconnlimit,
       has_database_privilege('local-gpt-work', datname, 'CONNECT') AS work_can_connect
FROM pg_database
WHERE datname IN ('binancebot_work', 'binancebot_work_baseline')
ORDER BY datname;"

sudo -u postgres psql -d binancebot_work_baseline -Atqc "
SELECT count(*)
FROM pg_class AS c
JOIN pg_namespace AS n ON n.oid = c.relnamespace
WHERE n.nspname IN ('bot', 'django')
  AND c.relkind IN ('r', 'p', 'S', 'v', 'm')
  AND pg_get_userbyid(c.relowner) <> 'local-gpt-work';"
# expected: 0
```

Also verify at the operating-system level that
`/usr/local/sbin/reset-binancebot-work` is root-owned and not writable by
`local-gpt-work`.

## Failure recovery

The script refuses to overwrite a candidate or previous baseline. Inspect the
reported state before taking any cleanup action.

- **Invalid/missing dump or insufficient space:** no database has been promoted.
  Correct the input or capacity problem and run a normal refresh.
- **Restore failed:** the candidate is deliberately left for inspection and is
  not resumable. After diagnosing the restore, an administrator must explicitly
  remove that candidate before starting a fresh restore. Never delete it until
  its state and the failure have been reviewed.
- **Candidate validation or protection failed after a successful restore:** fix
  the cause and resume with the exact same dump. The digest marker prevents a
  mismatched archive from being used.
- **Candidate promotion failed:** the script attempts to restore the old
  baseline's name. If that rollback also fails, stop and repair the database
  names manually before doing anything else.
- **Promoted-baseline validation or work reset failed:** the new baseline may
  already be active, and the work database may be missing because reset drops it
  before recreating it. The old baseline remains as
  `binancebot_work_baseline_previous`. Inspect both baselines, correct the cause,
  rebuild and verify the work database, and only then decide whether to remove
  the previous baseline. `--resume` does not apply after promotion.
- **A previous baseline already exists:** treat this as evidence of an
  interrupted refresh. Do not overwrite or automatically delete it. Determine
  which baseline is valid and whether the work database was successfully rebuilt
  before completing cleanup or rollback.

When recovery is ambiguous, preserve all databases and dumps and escalate to a
PostgreSQL administrator. The scripts intentionally prefer leaving recoverable
state over automatic cleanup.

## Repository contents

- `refresh_baseline.sh`: guarded administrative baseline refresh.
- `reset-binancebot-work`: reference copy of the narrowly scoped reset script.
- `do_snapshot.sh`: creates custom-format dumps under `snapshots/`.
