# BinanceBot database runbook

## Unattended PostgreSQL dump and restore

Run from the human-controlled checkout as `cristhian`. Stop Work and
application writers before restoring. Complete the
[helper and sudo prerequisites](SETUP.md#install-the-reviewed-binancebot-helpers)
first. An installation that only supports a dump pathname and optional
`--resume` needs the reviewed helper versions from the checkout for
checksum-based recovery and private stdin staging.

```bash
./db_refresh --full
./db_refresh --restore-only
```

`--full` requests a fresh custom-format dump from `service=vpsdatabase`
using the approved production read-only login. It validates the temporary
archive with `pg_restore --list`, decodes it, calculates SHA-256, and
publishes it with its checksum in a timestamped directory in
`$HOME/binancebot-snapshots`. The existing verified dumps are retained
when an acquisition fails.

`--restore-only` uses the newest published archive that still passes
checksum and archive checks. For an interrupted refresh it selects the
archive whose checksum matches the database recovery marker. A corrupt
archive is skipped and reported. An unknown candidate or a missing matching
archive requires review before continuing. Both modes use the installed
privileged helper to validate a protected candidate before promotion and to
recreate the disposable database from the new baseline. They verify Work
can connect and report the final database sizes and stage durations.

Use the same `--dump-dir DIR` in both modes if the archives live on a
different approved volume. Capacity checks include the candidate, Work
clone and archive staging. The read-only source size is an estimate before
capture, and the actual archive size is checked before restore. The
`--estimate-bytes` and `--reserve-bytes` options let the operator budget
for a larger restore or a higher free-space floor.

The helper streams the archive into one private PostgreSQL-owned spool.
`--jobs 2` can speed up independent table loads and index builds when the
host has spare CPU, I/O and memory. The default is one worker. Dump transfer,
integrity checks and the final `FILE_COPY` clone remain separate costs.
A verified repeat can skip the restore when the same archive is already
promoted and Work passes validation.

To detach from the terminal, create the private snapshot directory as
described in SETUP.md and start the command with `nohup`:

```bash
umask 077
log=$(mktemp "$HOME/binancebot-snapshots/db-refresh.XXXXXXXX.log")
nohup ./db_refresh --full >"$log" 2>&1 </dev/null &
printf 'PID %s  log %s\n' "$!" "$log"
```

The detached process needs noninteractive sudo and libpq authentication.
The final `Preparation verified` line means the database checks passed.
Failures name the stage and exit nonzero. SIGINT and SIGTERM exit with
130 and 143, respectively. After an interruption, run `--restore-only`.
The [recovery table](#recover-from-interruption) explains the database
markers and when a PostgreSQL administrator must inspect the state.

### Recover from interruption

Run `./prepare-codex-env --status` first. When the archive has been published,
reuse its exact directory or the original externally approved dump and
checksum. Use the printed stage, archive checksum and database markers to
locate the point of failure.

| Observed state | Recovery |
| --- | --- |
| Dump acquisition failed before publication | Correct authentication or capacity and rerun the explicit acquisition, or choose an existing verified snapshot. |
| Candidate is marked `restoring` | Reuse the identical archive. The installed helper restarts the restore after removing that marked partial candidate. |
| Candidate is marked `ready` or has the older completed-restore marker | Reuse the identical archive. The helper revalidates it and promotes it without restoring again. |
| Promoted baseline is marked `ready` | Reuse the identical archive. The helper retries Work reset and preserves a recognized previous baseline until Work validates. |
| Baseline is marked `complete`, with the matching previous baseline still present | Reuse the identical archive to verify Work and retire the prior baseline. |
| Candidate or previous baseline is unmarked, unrelated, or has unexpected ownership | Have a PostgreSQL administrator inspect the fixed names, their ACLs and active sessions before changing anything. |

Promotion renames the old and new baselines in a single PostgreSQL
transaction. If a stop lands between candidate creation and its first
marker, the unmarked candidate is left for administrator review. A forced
stop can leave a private temporary archive. The next capture cleans its own
`.incoming-*` directories under the capture lock, and the installed helper
cleans stale mode-`0600` PostgreSQL-owned `binancebot-refresh-v2.*.dump`
spools under its refresh lock. If a stale spool prevents the free-space
preflight from passing, ask the administrator to confirm that refresh is
idle before clearing it. Keep the published archive for recovery.

An active-session failure means a Work or application process must be
stopped before retrying. An installed-helper mismatch means a human needs
to review and install the current bytes. For a noninteractive sudo failure,
verify the approved human policy as described in [SETUP.md](SETUP.md).
Exit status zero means the requested stages finished. A failure returns
nonzero and names the stage. A handled interruption exits with 129, 130,
or 143 for HUP, INT, or TERM respectively.

## Prepare and launch an application workspace

From the human-controlled checkout, prepare a full approved application
commit with `prepare-work-workspace.sh`. Launch Work separately from the
human graphical session with the approved `PROD_VPS_IP` already available
to the launcher. Select the resulting workspace in ChatGPT Work. See
[WORKFLOW.md](WORKFLOW.md#prepare-the-binancebot-environment) for commands
and patch handoff, and [SETUP.md](SETUP.md#persistent-work-egress-protection)
for the separately administered UFW policy.
