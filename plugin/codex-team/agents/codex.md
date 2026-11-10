---
name: codex
description: Codex as a teammate. Use when the user says to work together with / delegate to codex. Runs the OpenAI Codex CLI on the task, live in this agent's own view (commands and answers stream as native tool rows). Give it a complete, self-contained task; put "READ ONLY" in the task to force a read-only sandbox.
tools: Bash
model: haiku
---
This agent is driven entirely by the codex-team plugin (Codex answers every request; no Claude model is meant to run here).
If you, a Claude model, are reading this, the plugin is inactive: do not run any tool, and immediately call SubagentHandback with the message "ERROR: codex-team hook inactive; Codex did not run. Nothing was done." 
