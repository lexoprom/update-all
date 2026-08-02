# DECIDE / EXECUTE Pattern

A lightweight, model-agnostic workflow for two agents in adjacent panes. In a
Herdr workspace, changed handoffs prompt the other agent through a small
stateless resolver (`scripts/de-route`); manual `go` remains the fallback. No
watcher, daemon, hook, state file, or dedicated shell pane is required.

`AGENTS.md` is the canonical protocol specification. This guide covers setup
and operation.

## Quick Use

1. Install once: `de-workflow init`. Use `de-workflow update` only to replace an existing installation.
2. Start in DECIDE for judgment or planning; otherwise start in EXECUTE.
3. In Herdr, a changed handoff prompts the other agent automatically. Otherwise,
   switch panes and type `go`.
4. Stop when the work is approved and committed.

EXECUTE acts on `# Plan`, `# Revise`, and `# Approved`. DECIDE acts on
`# Done`, `# Needs decision`, and `# Blocked`.

## Launcher

The `de-workflow` Zsh function creates a Herdr workspace in the current
directory with Codex as `decide` and Pi as `execute`. It starts the Herdr server
when needed; Herdr routes changed handoffs by prompting the sibling agent.

Requirements: `herdr` and `jq`.

```zsh
source ~/.zshrc
cd /path/to/project
de-workflow init
de-workflow
```

To install without launching:

```sh
./scripts/de-protocol install /path/to/project
```

To intentionally upgrade the current installation, preserving any `AGENTS.md`
preamble and `.de` handoffs:

```zsh
de-workflow update
```

From the canonical source checkout, upgrade another target with:

```sh
./scripts/de-protocol update /path/to/project
```

Agent names must be unique among live agents. Close an existing `decide` or
`execute` session before launching another workflow.

Optional agent arguments:

```zsh
DE_WORKFLOW_CODEX_ARGS='--full-auto' \
DE_WORKFLOW_PI_ARGS='--no-skills' \
de-workflow
```

## Routing

After successfully changing its outgoing handoff, a role checks `HERDR_ENV=1`.
If set, DECIDE runs `scripts/de-route execute` and EXECUTE runs
`scripts/de-route decide`, without `--wait`. No prompt is sent when the
handoff content did not change. If delivery fails, the handoff remains
authoritative and the operator can route it manually by typing `go`. Outside a
Herdr-managed session, all routing is manual. `de-route` resolves the sibling
pane by its `decide`/`execute` label within the current workspace and prompts
that pane's agent; it is stateless and runs only when invoked.

DECIDE handles requirements, decisions, plans, and review. EXECUTE explores,
implements, verifies, and commits. Clear work may start directly in EXECUTE.

```text
Clear task:       operator -> EXECUTE -> done
Ambiguous task:   operator -> DECIDE -> EXECUTE -> DECIDE review
Decision needed:  EXECUTE -> DECIDE -> EXECUTE
```

Escalate to DECIDE when:

- Requirements permit multiple interpretations.
- A design or compatibility choice is required.
- Security, money, user data, or public APIs are involved.
- Tests repeatedly fail for unclear reasons.
- EXECUTE cannot proceed without guessing.

If implementation would materially expand scope, touch unrelated modules, or
alter undecided public behavior, stop and escalate.

## Handoffs

Cross-pane messages use:

- `.de/decide-to-execute.md`, written only by DECIDE.
- `.de/execute-to-decide.md`, written only by EXECUTE.

Overwrite the outgoing file with the latest message. Use the files only when
work crosses roles; the working tree and `git diff` remain authoritative.

Initialize or check the protocol:

```sh
./scripts/de-protocol init
./scripts/de-protocol doctor
```

`init` creates missing local protocol files without overwriting messages.
Use `de-workflow update` to intentionally replace the managed `AGENTS.md`
section and installed workflow files. `doctor` checks the
required files, Git exclusion, and status headings. Neither command installs
hooks or starts background processes.

DECIDE headings:

- `# Plan` — implementation scope, constraints, and checks.
- `# Approved` — reviewed work may proceed or be committed.
- `# Revise` — corrections are required.
- `# Reject` — abandon the approach.

EXECUTE headings:

- `# Done` — changes and verification completed.
- `# Needs decision` — execution stopped for judgment.
- `# Blocked` — execution cannot continue.

Every `# Done` includes the verification command or manual check and its
outcome.

## Review and Commit

For reviewed changes:

1. DECIDE writes a precise plan.
2. EXECUTE implements and verifies it.
3. EXECUTE reports `# Done`.
4. DECIDE reviews the actual diff and verification evidence.
5. DECIDE replies with `# Approved`, `# Revise`, or `# Reject`.
6. EXECUTE commits only after approval.

Low-risk work may remain entirely in EXECUTE when the operator does not require
review. During the two-pane workflow, EXECUTE is the sole project-file writer.
If the operator assigns implementation to DECIDE, suspend the workflow and keep
EXECUTE idle.
