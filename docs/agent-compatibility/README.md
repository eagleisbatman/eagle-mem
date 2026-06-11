# Agent Compatibility Gate

Eagle Mem depends on external coding-agent lifecycle contracts. Hook, statusline, config, and instruction-file behavior can change independently of this repository, so these integrations must be reverified before they are edited.

## Required Workflow

Before modifying any file that changes Claude Code, Codex, OpenCode, Grok, Antigravity, hook, plugin, statusline, config-installation, or agent-instruction behavior:

1. Read the current official documentation for the affected agent surface.
2. Update the matching file in `docs/agent-compatibility/` with:
   - `Last verified: YYYY-MM-DD`
   - official source URLs
   - the exact behavior relied on
   - the Eagle Mem files that depend on that behavior
   - fixture or golden-test coverage that proves the behavior
3. Add or update a fixture or regression test for the behavior before editing implementation code.
4. Prefer additive compatibility changes when older installed users may still depend on the previous behavior.
5. Do not implement agent hook or statusline changes from memory.

## Sensitive Files

The compatibility gate applies to these file groups:

- `hooks/*.sh`
- `lib/hooks.sh`
- `lib/codex-hooks.sh`
- `lib/opencode-hooks.sh`
- `integrations/opencode_eagle_mem_plugin.js`
- `scripts/install.sh`
- `scripts/update.sh`
- `scripts/uninstall.sh`
- `scripts/doctor.sh`
- `scripts/statusline-em.sh`
- `lib/common.sh`
- `AGENTS.md`
- `CLAUDE.md` when present

The test `tests/test_agent_compatibility_docs_gate.sh` enforces that these docs and fixtures exist. When sensitive files are changed in an uncommitted worktree, the same test also requires a changed compatibility doc or agent-hook fixture in the same diff.

## Release-Gate Enforcement Scope

The feature-verification release gate (blocking `git push` / `npm publish` / `gh pr create` while changed files map to unverified features) is enforced inside `PreToolUse` for agents that have a hook lifecycle: **Claude Code** and **Codex** (and, via the plugin adapter, **OpenCode**). Two paths historically bypassed it:

- **Grok** is skills-and-CLI only — it has no hook lifecycle, so nothing intercepts its tool calls.
- A **bare-shell `git push`** (any terminal, any agent, or none) never reaches `PreToolUse`.

`eagle-mem gate` closes this gap at the git layer so governance is not silently skippable:

- `eagle-mem gate check` runs the same reconcile-and-block logic as the hook for the current repo, exiting non-zero when verifications are pending. It **fails open** (exit 0) when Eagle Mem is disabled (`EAGLE_MEM_DISABLE_HOOKS=1`), has no database, or the directory is not a recognized project — a git hook must never wedge unrelated pushes.
- `eagle-mem gate install [--repo PATH] [--force]` installs an **opt-in, repo-local** `pre-push` hook that calls `gate check`. It refuses to clobber a pre-existing non-Eagle-Mem `pre-push` hook unless `--force` is given. `eagle-mem gate uninstall` removes only the Eagle-Mem-managed hook.
- Bypass a single push with `git push --no-verify` (skips git hooks) or `EAGLE_MEM_DISABLE_HOOKS=1 git push`.

This is opt-in by design: Eagle Mem installs agent hooks globally but does not silently add git hooks to every repository. Coverage proof: `tests/test_release_gate_prepush.sh` (blocks on pending, fails open, install/foreign-protection/uninstall).
