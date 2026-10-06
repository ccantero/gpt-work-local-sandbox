# ChatGPT Work workflow

The infrastructure repository is a stable local control plane. Application
projects are transferred through a shared handoff area into separate disposable
Work workspaces; they are not developed inside the infrastructure checkout.

```text
Human repository:                 /home/cristhian/git/<project>
Shared handoff:                   /home/local-gpt-work/repos/
Infrastructure checkout:         /home/local-gpt-work/git/gpt-work-local-sandbox/
Disposable application workspace:/home/local-gpt-work/workspaces/<project>
```

The infrastructure checkout itself is the one exception to the snapshot
model. The human maintains its authoritative development checkout and will
publish reviewed commits through a normal GitHub repository. The isolated user
may clone or pull that infrastructure repository. This does not grant
`local-gpt-work` GitHub access to application repositories.

## Step 1: synchronize the human application repository

As `cristhian`, synchronize and review the real application repository using
the human's normal Git and GitHub credentials. Neither the infrastructure
checkout nor `local-gpt-work` performs this synchronization.

## Step 2: approve a source revision

Select a specific application commit after reviewing it. Versioned project
documentation such as `README.md`, `AGENTS.md`, `CHANGELOG.md`, and `docs/` is
the normal historical and architectural context available to Work.

## Step 3: prepare and consume deterministic source

Step 3 has two deliberately separate commands.

### 3A. Human-side handoff preparation

As `cristhian`, export the approved revision into new paths in a
human-writable staging directory:

```bash
./prepare-work-source.sh \
  /home/cristhian/git/oferta-hunter \
  <full-approved-commit-id> \
  /home/cristhian/work-handoff/oferta-hunter-<commit>.tar \
  /home/cristhian/work-handoff/oferta-hunter-<commit>.provenance
```

This command resolves the immutable commit, uses `git archive`, validates the
snapshot, and publishes a read-only source archive plus provenance. It does not
create a Work workspace or initialize Work's Git repository. It never copies
the human working tree, `.git`, untracked or ignored files, local `.env` files,
caches, dumps, remotes, credentials, SSH keys, or human Git configuration merely
because they exist locally. Files intentionally tracked by the approved commit
remain part of the approved snapshot.

Both output paths must be absent. An existing artifact is never overwritten.
After preparation, use the already-authorized human host procedure to place
copies in `/home/local-gpt-work/repos/`, owned by `local-gpt-work`. With the
verified `local-gpt-work:local-gpt-work 0755` directory, `cristhian` cannot
normally create files there directly; this repository does not invent an ACL,
shared group, or sudo rule to change that fact.

`local-gpt-work` intentionally controls its own `repos/` directory and may
modify, replace, or delete artifacts there. Mode `0444`, provenance, and
SHA-256 validation reduce accidental mistakes and detect an archive that no
longer matches its paired metadata; they are not a security boundary against
the isolated user.

### 3B. Isolated workspace initialization

As `local-gpt-work`, consume the prepared pair into a new application
workspace:

```bash
/home/local-gpt-work/git/gpt-work-local-sandbox/initialize-work-workspace.sh \
  /home/local-gpt-work/repos/oferta-hunter-<commit>.tar \
  /home/local-gpt-work/repos/oferta-hunter-<commit>.provenance \
  /home/local-gpt-work/workspaces/oferta-hunter
```

This command validates provenance and archive SHA-256, extracts tracked source,
and creates a new independent Git repository with exactly one deterministic
baseline commit, a clean status, and no remote. It contains no upstream history
or GitHub capability and exists only for local status, diff, patch, and review
material.

The target workspace must be absent. Even an empty existing directory is
rejected because it may represent work needing review. Never delete or replace
an existing workspace merely to make initialization proceed.

Before a future launcher starts Work, verify the workspace is clean, contains
one commit, and has no remotes. Work's directory will be the application
workspace—not the infrastructure checkout. A later launcher must combine
infrastructure rules with the application's own `AGENTS.md`; that instruction
composition and launching behavior are outside this step.

## Step 4: run and review Work

Not implemented here. Work will eventually run in the disposable application
workspace. It must not clone, fetch, pull, push, or publish application projects
to GitHub. Normal Git synchronization of the infrastructure checkout is a
separate control-plane operation.

## Step 5: return review material to the human

Not implemented here. Review diffs, patches, and reports will eventually return
through the shared handoff area. The human decides what to apply and remains
solely responsible for GitHub publication.
