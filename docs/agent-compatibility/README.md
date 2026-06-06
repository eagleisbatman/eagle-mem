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
