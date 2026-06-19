# Agent team workflow for cc-statusline

Generated 2026-06-19 by the `agent-team` skill.

## Team roster

| Role | Subagent type | Model | Tools |
|------|---------------|-------|-------|
| coder | coder | opus | (inherit all) |
| reviewer | reviewer | opus | Bash, Read, Grep, Glob, WebFetch + coordination |
| auditor | auditor | opus | Bash, Read, Grep, Glob, WebFetch + coordination |
| tester | tester | opus | Bash, Read, Grep, Glob, WebFetch + coordination |
| documenter | documenter | sonnet | Bash, Read, Grep, Glob, Edit, Write, WebFetch + coordination |
| release | release | sonnet | Bash, Read, Grep, Glob + coordination |

"+ coordination" = `SendMessage, TaskUpdate, TaskList, TaskGet`.

## Orchestrator workflow

You (the team lead) NEVER do implementation, review, audit, doc, or release
work yourself. You coordinate the team via Agent (spawn by `name` +
`subagent_type`) + SendMessage + the Task* tools.

Default flow for a typical task:
1. Spawn `coder` with the full task context. The coder runs `task ci` (and
   `task test-c-locale` for any width/string change) before reporting done.
2. After coder reports done, spawn `reviewer` + `auditor` IN PARALLEL with the
   coder's diff summary, changed file paths, and the report. If the change
   alters rendering/behavior, also dispatch `tester` on the fixture harness.
3. Resolve blocking findings by routing them back to coder via SendMessage
   (pin review scope to explicit commit SHAs; fixes land as follow-up commits,
   never amends after a SHA is dispatched).
4. Dispatch `documenter` to update `CHANGELOG.md` (terse `[Unreleased]` line)
   and any README/KNOWN_ISSUES that the change affects.
5. Before release, summarize what to verify end-to-end and STOP for user
   confirmation.
6. On user OK, spawn `release` (it folds `[Unreleased]` into the cut tag,
   pushes, waits for CI green, and creates the GitHub Release with the
   CHANGELOG notes).

## Claude Code team API note (2.1.183)

On this Claude Code version the session exposes a SINGLE IMPLICIT TEAM; the
`TeamCreate`/`TeamDelete` API and the Agent `team_name` parameter may be
absent/ignored. Spawn teammates with `Agent({name, subagent_type, prompt})`
(optionally `run_in_background: true`) and coordinate via `SendMessage`
(target by teammate name) + `Task*`. Graceful shutdown still works
(`SendMessage` a `shutdown_request`, await `shutdown_response approve: true`).
There is nothing to create or delete. If a `to: main` report bounces, ask the
teammate to re-send to the lead.

## Context handoff (CRITICAL)

Every teammate cold-starts with no memory of prior conversation or other
teammates' outputs. Whatever you write in the spawn `prompt:` is the entire
context they have, plus the body of `.claude/agents/<role>.md`.

Therefore every spawn prompt MUST include:
- File paths the teammate should read (the files being modified, `CLAUDE.md`,
  `KNOWN_ISSUES.md`, the relevant `tests/fixtures/*.json`).
- A summary of any prior teammate's findings when chaining workers.
- The exact error message / failing command output when retrying after a
  failure.
- If context is long, write it to `.claude/agent-team-tasks/<slug>.md` and
  reference that path. Put these task briefs (and all work) on the FEATURE
  branch, never the default branch.

## Project signals

- Test/lint gate: `task ci` (= `task shell:syntax` + `task shell:lint` +
  `task test` + `task test-c-locale`). Width/string changes: `task
  test-c-locale` is mandatory.
- Ad-hoc test: pipe a mock JSON into `bash statusline.sh` (one-liner in
  `CLAUDE.md`); expect exactly 2 stdout lines, exit 0, empty stderr.
- Test isolation env: `CC_STATUSLINE_SVC_CACHE`, `CC_STATUSLINE_SVC_FETCH`,
  `CC_STATUSLINE_NOW`, `STATUSLINE_PROFILE=0` (the harness sets these).
- Runtime toggles: `STATUSLINE_WIDTH`, `STATUSLINE_CACHE`, `STATUSLINE_PACE`,
  `STATUSLINE_DEBUG`.
- Release flow: manual recipe in `CLAUDE.md` (CHANGELOG fold + annotated tag +
  `git push --tags` + `gh run watch` + `gh release create`). GitHub `gh` CLI
  only; never `tea`/`fj-ex`.
- Spec dir: none.
- Authoring rules: `CLAUDE.md` (repo root), `KNOWN_ISSUES.md`. No
  `CONTRIBUTING.md`.
- CI: GitHub Actions (`.github/workflows/ci.yml`); SHA-pinned actions,
  `permissions: contents: read`, `persist-credentials: false`. Renovate
  handles dependency/action bumps.
- Shared asset: `images/screenshot.png` is shared with the hai blog post
  (`~/stuff/gitrepos/wxs/wxs/hai/content/ai-stuff/claude-statusline.md`); a
  visual change means updating both.
- Slash commands the orchestrator may invoke between delegations: none in-repo
  (`.claude/commands/` is empty).
