# DECIDE / EXECUTE Instructions

This repository supports an operator-guided two-agent workflow with automatic
Herdr handoffs when available. The default launcher maps Codex to DECIDE and Pi
to EXECUTE. An explicit operator assignment overrides that default.

## Roles

- DECIDE handles requirements, plans, decisions, and review. It must not modify
  project files; it may write only `.de/decide-to-execute.md`.
- EXECUTE explores, implements, verifies, and commits. It is the sole
  project-file writer and may write only `.de/execute-to-decide.md` among
  the protocol files.
- Both roles may read the entire working tree and both protocol files.

## Exchange Protocol

- Use the protocol files only when work crosses roles.
- Overwrite your outgoing file with the latest message; do not append history.
- Never edit the other role's file.
- After successfully changing an outgoing handoff, if `HERDR_ENV=1`, prompt the
  other live agent without `--wait`: DECIDE runs `scripts/de-route execute`;
  EXECUTE runs `scripts/de-route decide`. Do not prompt if the outgoing
  content did not change. `de-route` resolves the sibling pane by its
  `decide`/`execute` label in the current workspace and prompts it; it is
  stateless and runs only when invoked.
- If that prompt fails, leave the completed handoff untouched, report the
  delivery failure, and let the operator route it manually with `go`. Do not
  poll, watch, or install hooks.
- When the operator says `go` in either pane, treat it as notice that the other
  role finished: read the other role's latest protocol message and act on its
  heading. This remains the fallback outside Herdr or after delivery failure.
- The working tree and `git diff` are authoritative; handoff summaries are not.

DECIDE starts each message with one of:

- `# Plan` — implementation scope, constraints, and acceptance checks.
- `# Approved` — reviewed work may proceed or be committed.
- `# Revise` — corrections are required.
- `# Reject` — abandon the current approach.

EXECUTE starts each message with one of:

- `# Done` — changed files and verification evidence.
- `# Needs decision` — facts, options, and the exact decision required.
- `# Blocked` — the concrete blocker and attempted remedies.

When EXECUTE reports `# Done`, DECIDE must inspect the actual diff and
verification evidence before approving it. When EXECUTE reports
`# Needs decision` or `# Blocked`, it must stop the affected work rather than
guess. After `# Approved`, EXECUTE commits and stops; it does not write another
`# Done` solely to report that commit.

## Local Commands

```sh
./scripts/de-protocol init
de-workflow update
./scripts/de-protocol doctor
```

See `DECIDE-EXECUTE.md` for the complete workflow.
