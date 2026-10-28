# Agent Harness OS

A **concept** for an "operating system" that lets AI agents take a requirement or user story and deliver
tested, traceable changes, working autonomously within rules, with humans handling exceptions.
It's meant to scale from a tiny single-repo app to a large, safety-relevant system (e.g. automotive)
spread across many repos, source-control systems and trackers.

Everything here is conceptual. YAML snippets and tables are illustrations, not final formats.

## Docs

| Doc | Question it answers |
|---|---|
| [00-overview](00-overview.md) | Core ideas, golden rules and glossary. **Start here.** |
| [01-repo-local-files](01-repo-local-files.md) | What belongs in a repo (README, CONTRIBUTING, AGENTS.md, manifest), and what must live centrally? |
| [02-recursive-v-model](02-recursive-v-model.md) | How a requirement is broken down, built, integrated and tested; handling changes mid-work |
| [03-tracker-adapters](03-tracker-adapters.md) | Connecting to Jira, Azure DevOps, GitHub Issues, Polarion…, possibly several at once |
| [04-where-the-harness-lives](04-where-the-harness-lives.md) | Where the harness's program, rules and memory (ledger) live |
| [05-starting-and-steering-work](05-starting-and-steering-work.md) | How people deliberately start, preview, pause and stop agent work |
