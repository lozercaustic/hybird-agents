# codex-team

A Claude Code mod that adds Codex as a native subagent. Codex plays the subagent's model through the `turn.step` hook: each command Codex runs shows as a real Bash row in the agent view, and its answer is handed back to Claude as the subagent's report.
Say "work together with codex to do X" and Claude spawns `codex-team:codex`.
