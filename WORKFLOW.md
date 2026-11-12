# ChatGPT Work workflow

Use the current human-controlled checkout to prepare an approved application
workspace and to launch ChatGPT Work as `local-gpt-work`. `README.md` defines
the architecture; `SETUP.md` is authoritative for host installation and
persistent UFW lifecycle. `RUNBOOK.md` documents database operation and
recovery.

## Refresh the BinanceBot databases

From the human-controlled checkout, use `./db_refresh --full` to capture
and restore a fresh production dump, or `./db_refresh --restore-only` to
retry from a verified local dump. The
[database runbook](RUNBOOK.md#unattended-postgresql-dump-and-restore)
covers detached execution and recovery.

## Prepare the BinanceBot environment

Run from the human-controlled checkout after completing
[helper installation](SETUP.md#install-the-reviewed-binancebot-helpers). Stop
Work and application writers before a refresh or reset.

```bash
./prepare-codex-env --status
./prepare-codex-env --check
./prepare-codex-env --list-dumps
./prepare-codex-env --refresh
./prepare-codex-env --reuse-dump "$HOME/binancebot-snapshots/<snapshot-directory>"
./prepare-codex-env --reset-work
```

`--refresh` explicitly requests a new production snapshot. `--reuse-dump`
operates locally and accepts a managed snapshot directory or an approved
archive file with `--sha256 <approved-digest>`. Reset discards changes in the
disposable Work database. A matching completed snapshot with usable Work is
reused as-is. If a refresh fails after the dump is published, use the printed
archive path with `--reuse-dump`.

Prepare the approved Git commit in its own workspace:

```bash
./prepare-work-workspace.sh --ensure \
  /absolute/path/to/application-repository '<full-approved-commit-id>' '<workspace-name>'
```

Reusing the workspace name and approved commit preserves existing workspace
changes. Choose a new name for a clean task. Launch and select the workspace
using [Routine launch](#routine-launch). See
[the database runbook](RUNBOOK.md#unattended-postgresql-dump-and-restore) for first
execution, recovery, and troubleshooting.

## Firewall operational implications

The `run-work.sh` temporary IPv4 `iptables` protection is still
required. It adds a UID/destination reject when the launcher
starts and removes only a rule that invocation added during normal cleanup.

After a human administrator has installed and accepted the persistent UFW
policy in `SETUP.md`, both controls may coexist. The persistent policy survives
launcher exit and reboot; the launcher continues to provide its existing
per-session defense. A launcher simplification or removal of its temporary
rule is deliberately a separate follow-up change. It requires all of these:

1. persistent-policy installation and validation, including reboot;
2. explicit human-administrator approval; and
3. a separately reviewed implementation and rollback plan.

Work must not invoke the UFW helper, inspect production endpoints, modify
firewall state, or receive new sudo privileges. Only an administrator runs the
protected helper. General Internet access remains governed by the host's
existing UFW policy; the persistent block applies solely to the Work UID and
administrator-approved destination addresses.

## Routine launch

From the human graphical session, export the currently approved IPv4
as `PROD_VPS_IP` if the session has yet to set it. Then launch Work:

```bash
./run-work.sh
```

If the temporary rule or launcher cleanup reports an error, do not alter the
persistent UFW policy as an ad-hoc fix. Stop, retain the output for review, and
have the administrator follow the inspection/recovery procedure in `SETUP.md`.

## Return review material to the human

Record the Work workspace's initial commit before making changes. At
handoff, prepare a self-contained implementation report and a patch from that
commit through the final state. Include staged, unstaged, and new files
when they are part of the deliverable. Record the patch's SHA-256 and keep
deliverables outside the application Git index.

The human copies the patch to a protected review directory, verifies the
checksum, and checks it against the approved human application checkout:

```bash
sha256sum /path/to/WORK_CHANGES.patch
git -C /path/to/human-owned/application-repository apply --check \
  /path/to/WORK_CHANGES.patch
```

The human then applies the patch, inspects the actual diff, reruns the relevant
tests, and decides whether to create an independent commit. Work and human
commit histories are independent. Keep the Work workspace Work-owned with no
remote.
