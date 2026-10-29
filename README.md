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
| [06-seeing-what-the-harness-is-doing](06-seeing-what-the-harness-is-doing.md) | Observability: viewing the work tree and progress at any stage; plug-in views |
| [07-the-reconciler](07-the-reconciler.md) | The reconciler (harness loop): what it does, why it isn't AI, how to start and stop it |
| [08-leaves-and-parallel-work](08-leaves-and-parallel-work.md) | Where leaves are cut (vertical slices), and parallel agents with a landing queue instead of locks |

## Try it: the simulator

[`AgentOS/Simulator`](AgentOS/Simulator) is a small working Swift model of these concepts: a Mac app and a CLI.
It runs a mock tracker, the reconciler, a hash-chained ledger and agents (scripted or Copilot CLI), which
work on branches of a real git monorepo, land through a landing queue and are checked with `swift test`.
Open `AgentOSSimulator.xcodeproj` there to run the app, or run `swift run agentos demo` in its `AgentOSCore` folder.
