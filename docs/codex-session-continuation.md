# Codex Session Continuation — OpenCode Setup (2026-09-08)

Continuation of Codex session `01a07c6c` (2026-09-07). Prior full report:
`D:\Softwares\Codex\OPENCODE_SETUP_REPORT.md`. This note only records what still
holds, what changed in status, and how to undo. No global config was rewritten here.

## Like I'm 5

Your toy workshop was fixed yesterday. Today we opened the door and checked:
instruction book still in one place, helper box still the right version, doors
still where they should be. One door (Obsidian) is closed because the shop behind
it is closed — that is expected, not broken. Nothing was thrown away today.

## Verified 2026-09-08 (read-only, secrets redacted)

- Artifacts: report True, `opencode-audit-2026-09-07/` True (25 files),
  backup `D:\backups\opencode-audit-20260907-233019` True.
- Resolved config (`opencode debug config` exit 0): model
  `omniroute/fries-in-the-bag`, default `orchestrator`, single plugin origin
  `.../.config/opencode/node_modules/oh-my-opencode-slim` (global), Obsidian
  `remote http://127.0.0.1:27123/mcp/ enabled:true`, `crazy-rapid-boots` primary
  present, all variants null (8x `max` removal holds).
- Deps: `.config/opencode` plugin `1.18.21` + slim `2.2.18`; `.opencode` only
  plugin `1.18.21`; installed slim `2.2.18`.
- MCP (`opencode mcp list` exit 0): 5/6 connected (playwright, filesystem, github,
  context7, gh_grep). Obsidian FAILED — app closed (`Get-Process obsidian` empty).
  Expected-offline per prior limit, not config drift. Not auto-started.
- Bakunawa repo: `main...origin/main`, 7 modified + 5 untracked, `git diff --check`
  clean, HEAD `b320cd6`. No commits (per user rule).

## Still true from yesterday (not re-proven today)

- Small model request HTTP 200 ~12s; 44 OmniRoute capacity-busy errors remain an
  upstream limit — local cleanup does not fix server traffic jams.
- No proven startup speedup (single samples 2.43s vs 2.91s are not a benchmark).
- Node `24.7.0` vs `ini@7.0.0` range warning remains for a separate runtime update.
- Caches, global CLI, dev checkout retained intentionally; only exact duplicates were
  the two `.gitignore` files.

## Rollback (from prior report, unchanged)

Originals at `D:\backups\opencode-audit-20260907-233019` (contains credentials — keep local).
Close OpenCode first, restore via `restore-manifest.json`, then if needed reinstall
removed secondary tree from restored manifest (`npm install` in `~/.opencode`).

## Next

- Open Obsidian to restore 6/6 MCP when you need live vault tools; filesystem access
  works while closed.
- Start a fresh OpenCode session to load current settings.
- Keep model choice unless new measurements give a reason to change.
