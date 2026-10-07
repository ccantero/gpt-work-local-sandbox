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
  -> diff, patch, and report for human review
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

The complete two-account Step 3 flow was validated on the reference host. An
approved commit containing tracked `.gitignore` and `hello.txt` plus an ignored,
untracked `.env` produced an archive containing only the tracked files and no
`.git` directory. The restricted account then initialized a clean workspace
with exactly one baseline commit, no remote, no `.env`, and provenance pointing
to the approved upstream commit. A simulated Work edit changed only
`hello.txt`; `git status --short` and `git diff` reported exactly that change.

Before a future launcher starts Work, verify the workspace is clean, contains
one commit, and has no remotes. Work's directory will be the application
workspace, not the infrastructure checkout. Instruction composition and
launching behavior belong to Step 4 and remain outside this completed step.

## Step 4: run and review Work

Not implemented here. Work will eventually run in the disposable application
workspace. It must not clone, fetch, pull, push, or publish application projects
to GitHub. Normal synchronization of the public infrastructure checkout is a
separate control-plane operation.

## Step 5: return review material to the human

Not implemented here. Review diffs, patches, and reports will eventually return
through the handoff area. The human decides what to apply and remains solely
responsible for publication.
