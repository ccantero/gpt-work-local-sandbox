# ChatGPT Work workflow

The infrastructure repository is a stable local control plane. Application
projects are transferred from a human-owned repository through a handoff area
into separate disposable Work workspaces; they are not developed inside the
infrastructure checkout.

```text
human-owned application repository
  -> approved Git commit
  -> git archive plus provenance
  -> source handoff
  -> disposable application workspace
  -> independent one-commit Git repository with no remote
  -> Work changes and tests
  -> patch and report outside the application repository
  -> human verification, application, review, and testing
  -> independent human commit, if accepted
```

The infrastructure checkout is the one exception to the archive model. This
repository is public, so the restricted Work account may clone and pull it over
public HTTPS without a GitHub token, SSH key, or human credentials. This
control-plane access does not grant that account access to private application
repositories; those continue to use the archive-and-provenance handoff below.

Example paths use `<work-home>` for the restricted account's home and
`<human-staging>` for a human-writable staging directory. On the validated
installation, `<work-home>` is `/home/local-gpt-work`.

## Step 1: synchronize the human application repository

The human operator synchronizes and reviews the real application repository
using the human's normal Git credentials. Neither the infrastructure checkout
nor the restricted Work account performs this synchronization.

## Step 2: approve a source revision

Select a specific application commit after reviewing it. Versioned project
documentation such as `README.md`, `AGENTS.md`, `CHANGELOG.md`, and `docs/` is
the normal historical and architectural context available to Work.

## Step 3: prepare and consume deterministic source

Step 3 has two deliberately separate commands.

### 3A. Human-side handoff preparation

As the human operator, export the approved revision into new paths in a
human-writable staging directory:

```bash
./prepare-work-source.sh \
  /path/to/human-owned/application-repository \
  <full-approved-commit-id> \
  <human-staging>/<project>-<commit>.tar \
  <human-staging>/<project>-<commit>.provenance
```

This command resolves the immutable commit, uses `git archive`, validates the
snapshot, and publishes a read-only source archive plus provenance. It does not
create a Work workspace or initialize Work's Git repository. It never copies
the human working tree, `.git`, untracked or ignored files, local `.env` files,
caches, dumps, remotes, credentials, SSH keys, or human Git configuration merely
because they exist locally. Files intentionally tracked by the approved commit
remain part of the approved snapshot.

Both output paths must be absent. An existing artifact is never overwritten.
After preparation, use an already-authorized host procedure to place copies in
`<work-home>/repos/`, owned by the restricted account. This repository does not
invent an ACL, shared group, or sudo rule for that transfer.

The restricted account intentionally controls its handoff directory and may
modify, replace, or delete artifacts there. Mode `0444`, provenance, and
SHA-256 validation reduce accidental mistakes and detect an archive that no
longer matches its paired metadata; they are not a security boundary against
the artifact owner.

### 3B. Restricted workspace initialization

As the restricted Work account, consume the prepared pair into a new
application workspace:

```bash
<work-home>/git/gpt-work-local-sandbox/initialize-work-workspace.sh \
  <work-home>/repos/<project>-<commit>.tar \
  <work-home>/repos/<project>-<commit>.provenance \
  <work-home>/workspaces/<project>
```

This command validates provenance and archive SHA-256, extracts tracked source,
and creates a new independent Git repository with exactly one deterministic
baseline commit, a clean status, and no remote. It contains no upstream history
or GitHub capability and exists only for local status, diff, patch, and review
material.

The target workspace must be absent. Even an empty existing directory is
rejected because it may represent work needing review. Never delete or replace
an existing workspace merely to make initialization proceed.

### Completed validation

The complete two-account source preparation and workspace initialization flow
was validated on the reference host. The resulting workspace contained only
approved tracked source, had a clean independent baseline commit and no remote,
and excluded repository metadata and untracked or ignored source-tree files.

Before launching Work, verify the workspace is clean, contains one commit, and
has no remotes. Work's directory will be the application workspace, not the
infrastructure checkout.

## Step 4: run and review Work

From a terminal inside the human Linux user's existing graphical login, supply
the production VPS IPv4 address without recording it in the repository and run:

```bash
PROD_VPS_IP='<production-vps-ip>' \
  <work-home>/git/gpt-work-local-sandbox/run-work.sh
```

The launcher is run by the human, not from a separate graphical login for
`local-gpt-work`. It grants the restricted account access to the human's X
display, checks or adds an owner-matched firewall reject rule for the supplied
address, and uses `sudo -u local-gpt-work` to start the installed ChatGPT
application with the restricted account's runtime and D-Bus paths. Cleanup
revokes graphical access and removes the firewall rule only if this invocation
added it.

After ChatGPT opens, the human selects the initialized application workspace in
ChatGPT Work. Workspace selection remains an explicit UI step; `run-work.sh`
only starts the application. Work must not clone, fetch, pull, push, or publish
application projects to GitHub. Normal synchronization of the public
infrastructure checkout is a separate control-plane operation.

The current launcher behavior is deliberately preserved. Better logging, sudo
prompt handling, firewall lifecycle, and process shutdown behavior are known
follow-up work rather than part of this launcher replacement.

## Step 5: return review material to the human

Work may implement changes, run tests, and create multiple local commits inside
the disposable workspace. At the end, it writes its implementation report and
patch outside the application repository, preferably under
`<work-home>/deliverables`, so review artifacts cannot accidentally enter an
application commit. The patch must represent the complete difference between
the initialized Work baseline and final `HEAD`, not merely the last Work
commit. Record its SHA-256 before transfer.

The human copies the report and patch to a human-owned review location, verifies
the recorded checksum, and checks the patch against the approved original
application repository before changing it:

```bash
sha256sum /path/to/WORK_CHANGES.patch
git -C /path/to/human-owned/application-repository apply --check \
  /path/to/WORK_CHANGES.patch
```

If those checks succeed, the human applies the patch, inspects the actual diff,
runs the relevant test suite, and decides whether to create a new human-side
commit. Work's internal commits and the human repository have independent
histories, so Work commit hashes must not be used for Git operations in the
human repository. The patch is the supported integration mechanism. Direct
human Git access to the Work workspace is unnecessary; do not add
`safe.directory`, change workspace ownership, or create shared Git access for
this purpose.

### Completed E2E validation

The complete application handoff, isolated implementation, patch return, and
human review and integration workflow was successfully validated end to end.
The validation confirmed that application development requires neither a
remote nor GitHub credentials in the Work repository and that the patch is a
sufficient boundary between the independent Work and human Git histories.

The preferred future output directory, `/home/local-gpt-work/deliverables`,
was created after this run with owner `local-gpt-work` and mode `0755`. Its use
has therefore been prepared but not yet validated end to end.
