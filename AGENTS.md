# AGENTS.md

Guidance for AI agents (and people) changing this repo. The harness's own commands live in
`.agentos/config.json`. That file is the source of truth for how work is built and tested; this one covers how
to write code that fits.

## What's here

- `00-…08-*.md` (repo root): the **concept docs**. They describe the harness in general and stay
  tool- and repo-agnostic. Don't put details of the Swift app in them.
- `AgentOS/HarnessApp/`: the Swift harness app.
  - `AgentOSKit/`: Swift package with all the logic.
  - `App/`: the SwiftUI Mac app.
  - `docs/real-repo-mode.md` and `README.md`: user-facing docs for the app. Update them when behaviour
    changes (signals, statuses, scan findings, settings).
- `AgentOS/Simulator/`: older standalone simulator project. Leave it alone unless a ticket names it.

## Module layering (AgentOSKit)

| Target | May contain | Must not contain |
|---|---|---|
| `AgentOSCore` | Model, ledger, reconciler, policy, protocols for everything outside the harness | UI, file system, processes, network |
| `AgentOSAdapters` | Real implementations: file stores, trackers (local, GitHub), git workspace, check runners, Copilot CLI agents, readiness scan | SwiftUI |
| `AgentOSSimulation` | Simulated world: scripted agents, simulated workspace and external system, demo content | Anything the real-repo mode depends on |
| `AgentOSUI` | SwiftUI panes shared by all windows | Adapters (depends on `AgentOSCore` only) |
| `agentos` | Headless demo runner | |

New tracker, workspace or agent behaviour starts as a protocol in `AgentOSCore`, with a real version in
`AgentOSAdapters` and a simulated or fake one for tests.

## Ledger and reconciler rules

- State changes only by writing `LedgerEvent`s. Never change `WorkingState`/`NodeState` directly; they're
  rebuilt from the ledger.
- Only humans open gates (breakdown, build) and approve reviews. Agents and the reconciler must not.
- Adding an `EventKind` case is fine; renaming or removing one breaks existing ledgers. Old ledgers must still
  read.
- Human-facing text (tracker comments, rejections, next-step hints, statuses) must say what happened and
  what the human can do next, with the signal label to use (for example `harness:retry`).
- Statuses shown to people come from `WorkingState.status(of:)`. Don't make up status words in the UI.
- An implementer must never edit another node's acceptance tests to make its own change pass.

## Tests

- Use **Swift Testing** (`import Testing`, `@Test`, `#expect`). No XCTest.
- Put tests in the target that matches the code: `AgentOSCoreTests`, `AgentOSAdaptersTests`,
  `AgentOSSimulationTests` or `AgentOSUITests`. End-to-end reconciler behaviour usually goes in
  `AgentOSSimulationTests`.
- Test names say the behaviour, for example `aPreviewsQuestionsCanBeAnsweredInAComment`.
- Tests that touch SwiftUI views or `@MainActor` types must be `@MainActor`. Otherwise the test process
  crashes (signal 5) instead of failing.
- Compare JSON by parsing it, never as strings: key order isn't stable.
- In simulation tests, the last tracker comment is often the harness's reply to a signal. Check
  `comments.contains` rather than `lastComment`.
- If tests fail in ways that make no sense after changing enums such as `EventKind`, run `rm -rf .build`
  in `AgentOSKit` and try again.

## Commands

```sh
# Tests (what the harness runs)
cd AgentOS/HarnessApp/AgentOSKit && swift test

# App build (regenerate the project first if project.yml changed)
cd AgentOS/HarnessApp && xcodegen generate
xcodebuild -project AgentOSHarness.xcodeproj -scheme AgentOSHarness -destination 'platform=macOS' build -quiet
```

## Style

- Follow the surrounding code. Short doc comments on types and non-obvious functions; no comments that
  repeat the code.
- Keep changes to what the ticket asks for. Don't edit `AGENTS.md`, `CODEOWNERS`,
  `.github/copilot-instructions.md` or `.agentos/`: the harness rejects changes to them.
