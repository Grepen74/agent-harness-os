# Contributing

Most changes here are made by the harness's own agents, working from GitHub issues; people review and steer
them. The same rules apply to everyone.

- **Rules for code, tests and docs:** [AGENTS.md](AGENTS.md). Read its **Tests** section before writing one:
  tests must pass when the whole suite runs on a busy machine, so they never depend on timing, wall-clock
  time or what other tests do, and never pin lists or files that later tickets will change.
- **How the harness works on this repo:** [AgentOS/HarnessApp/docs/real-repo-mode.md](AgentOS/HarnessApp/docs/real-repo-mode.md).
- **Concepts:** the numbered documents at the root, starting with [00-overview.md](00-overview.md).

Run the tests with `cd AgentOS/HarnessApp/AgentOSKit && swift test` before submitting a change.
