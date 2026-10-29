# Design: running the harness on a real repo

> Status: **proposal**. App-specific design for the harness app. The generic concepts it builds on are in
> the concept docs: repo files and the readiness scan ([01](../../../01-repo-local-files.md)), the V and leaves
> ([02](../../../02-recursive-v-model.md), [08](../../../08-leaves-and-parallel-work.md)), policy layers and
> storage ([04](../../../04-where-the-harness-lives.md) §3, §8), gates and readiness
> ([05](../../../05-starting-and-steering-work.md)).

## Goal

Point the app at a real Mac/iOS repo on this machine and let the harness work there: from a ticket, through
breakdown, tests and implementation, to proven changes on a local branch. Use the simulator's UI to steer it
and watch it. Keep it simple: one machine, one repo, one user.

The simulator stays. It becomes one of two kinds of window in the same app.

**Not in scope yet:** several repos forming one system (integration nodes), shared or cloud storage, more
than one user, pushing or opening pull requests.

## How it's used

1. **Open Repository…** and choose a git repo.
2. The **readiness scan** runs and shows its findings. Blockers must be fixed before work can start;
   warnings can be accepted.
3. The scan **drafts a repo config** from what it found: how to build and test, components, test
   locations. You review it, and it only counts once it's committed on `main`.
4. Tickets come from a tracker adapter. Without one, the app's **local tracker** is used (the simulator's
   tracker pane, persisted).
5. From here it's the simulator's flow, on real code: preview → breakdown → tests → build → pre-check →
   landing queue → proven.
6. Proven work lands on the local branch **`agentos/main`**. You review, merge and push it yourself.

## What changes compared to the simulator

| | Simulator | Real repo |
|---|---|---|
| Repo | Created by the harness, `Package.swift` generated | Exists. The harness never restructures it, so it must **discover** how it's built |
| Build and test | `swift test`, hard-coded | Commands from the repo config, e.g. `xcodebuild test -scheme App -destination 'platform=iOS Simulator,name=iPhone 14,OS=18.6'` |
| A leaf's tests | A new test target per leaf | Files in an **existing** test target, in a suite named after the leaf, run with `-only-testing:` (XCTest and Swift Testing). The protected-tests fingerprint covers those files |
| Components (touch set) | `Sources/<Component>` folders | Detected: Swift package targets, Xcode targets, or top-level folders; listed in the repo config |
| Agents | Scripted or Copilot CLI | Copilot CLI only. It already reads AGENTS.md and `.github/copilot-instructions.md` |
| Working copies | Harness-owned folder | Git worktrees **outside** the repo folder; your own checkout is never touched |
| Landing | Fast-forward `main` | Fast-forward `agentos/main` (configurable, see Policy) |
| Check duration | Seconds | Minutes. The landing queue is the bottleneck; acceptable for now |

### The Xcode project file

If the project uses explicit file references, every new file changes `project.pbxproj`. That makes it the
biggest merge hotspot in an Xcode repo (doc 08 §8). The scan checks for it and suggests fixes:
- **Folder-synchronized groups** (Xcode 16+): new files appear without project changes. Best fix.
- **A generated project** (XcodeGen, Tuist): the project file is generated, ideally not committed. The repo
  config then names the generate command, and the harness runs it before each check.
- Otherwise: a warning, and expect reworks on `project.pbxproj`.

## Policy: two layers, shown with their source

Following doc 04 §8, the app's own **harness settings** set the outer limits, and the repo's
**`.agentos/config`** may only choose within them or make them stricter. The repo config is read from
`main` only.

| Setting | Harness default (limit) | Repo may |
|---|---|---|
| Landing target | Local branch `agentos/main` | Choose another *local* branch name |
| Push / open pull requests | Never | Nothing (later: allowed only if the harness allows it) |
| Agent tools | Copilot CLI, with `git push` and network installs denied | Deny more |
| Max attempts / reworks per leaf | 3 / 3 | Lower |
| Max parallel agents | 2 | Lower |
| Signals people may use (doc 05 §3) | All, including `harness:go` | Switch some off, e.g. `go` to force a breakdown review |
| Required checks | Build + the leaf's tests on branch; all tests at landing | Add more (lint, snapshot tests…) |
| Protected paths | Tests of proven leaves, `.agentos/`, AGENTS.md, CONTRIBUTING, CODEOWNERS | Add more |

The UI shows every effective value with its source (*harness*, *repo*), and a repo value that tries to
loosen a limit becomes a finding, not a silent override.

The repo config is the manifest from doc 01 in a simple form, for example:

```yaml
# .agentos/config: illustration only
build:  { prepare: "xcodegen generate", command: "xcodebuild build -scheme App -destination 'platform=macOS'" }
test:   { command: "xcodebuild test -scheme App -destination 'platform=macOS'",
          only: "-only-testing:AppTests/{suite}" }
leaf_tests: { target: AppTests, folder: "AppTests/Acceptance" }
components: [App/Features/Weather, App/Services, Packages/Networking]
landing: { branch: agentos/main }
signals: { disable: [go] }   # may only remove signals the harness offers
```

## Readiness scan for an Xcode repo

| Check | Severity if it fails |
|---|---|
| It's a git repo with at least one commit; the default branch is found | Blocker |
| A way to build and test is found or configured, and **tests pass on `main`** (the baseline) | Blocker |
| The repo config is valid and doesn't loosen any harness limit | Blocker |
| AGENTS.md or copilot-instructions exist and say how to build and test | Warning |
| README explains what this is; CONTRIBUTING has a Definition of Done | Warning |
| No `project.pbxproj` hotspot (see above) | Warning |
| A test target for acceptance tests exists; the test framework is known | Warning |
| The simulators and SDKs the test command needs are installed | Warning |
| CODEOWNERS covers the files that steer agents | Info (Warning for stricter profiles) |
| Uncommitted changes in your checkout | Info: the harness works from `main` and won't include them |

Findings appear in their own pane and are recorded in the ledger. New findings during work (a flaky
test, a leaf touching files outside its touch set, repeated reworks on the same file) appear there too.

## Storage

The harness's state for a repo is private and lives outside the repo:

```
~/Library/Application Support/AgentOS/repos/<repo-id>/
  ledger.jsonl     events, hash-chained
  tracker.json     local tracker tickets (when no tracker adapter is configured)
  artifacts/       check logs (evidence)
  worktrees/       one working copy per leaf
```

`<repo-id>` is derived from the repo's first commit plus its path, so two clones of the same repo don't
share state by accident.

Code talks to storage through small protocols, with file-based adapters first:
- `LedgerStore`: append records; read all records. The ledger itself checks node versions
  (compare-and-swap) before it appends.
- `TicketStore`: the local tracker's tickets.
- `ArtifactStore`: put a file, get its path and checksum.

SQLite and server-based adapters can be added later without touching the reconciler.

## Packaging

The app and the harness are split so the harness core never depends on the simulator or the UI:

| Package / target | Contains |
|---|---|
| `AgentOSCore` | Model, ledger and working state, reconciler, policy, the adapter and store protocols |
| `AgentOSAdapters` | Git workspace, config-driven check runner, Copilot agents, local tracker, file stores, readiness scan |
| `AgentOSSimulation` | Mock tracker and external system, scripted agents, demo content, the `agentos` CLI |
| `AgentOSUI` | Shared panes: tracker, work tree, ledger, findings, settings |
| App (Xcode target) | Two kinds of window: **repository** (File → Open Repository…) and the **simulator** |

All four live in one Swift package, `AgentOSKit`. Dependencies point one way: Adapters, Simulation and UI
depend on Core, never the reverse. The panes read a `HarnessViewModel` and send requests to a
`HarnessActions` backend, so the same panes serve both window kinds.

## Safety

- The user's own checkout is never written to. Agents work in worktrees outside the repo folder.
- Nothing is pushed. Landing only moves a local branch.
- Agent processes get a clean environment and restricted tools (`git push` denied).
- Files that steer agents (AGENTS.md, CONTRIBUTING, CODEOWNERS, `.agentos/`) are protected: a leaf that
  changes them fails its check, like changing someone else's tests.

## Phases

Each phase is usable on its own.

1. **Package split and storage protocols.** File adapters; rename the folder. The simulator behaves exactly
   as before. *Done.*
2. **Readiness scan and findings pane.** Read-only, so it's safe to run on any repo. Pilot: this repo. *Done:*
   File → Open Repository…, `agentos scan`. Checking simulators and SDKs waits for the configured test
   command (phase 3).
3. **Repo config and policy layers.** Settings pane with sources; a check runner driven by the config;
   baseline check on `main`.
4. **Real workspace.** Worktrees outside the repo, a leaf's tests in an existing target, landing on
   `agentos/main`, Copilot agents with restricted tools.
5. **GitHub Issues adapter**, as the first real tracker.

## Pilot: this repo

The first repo to try is this one (`agent-harness-os`). The first scan (phase 2) found what was expected:
- Blocker: no repo config. Only one test entry point was found (`swift test` in `AgentOSKit`), because
  the app target has no tests.
- Warnings: no AGENTS.md or copilot-instructions; no CONTRIBUTING; `project.pbxproj` is generated by
  XcodeGen but committed (hotspot); the app target has no test target.
- Info: Swift package `AgentOSKit` using Swift Testing; the XcodeGen project; no CODEOWNERS; baseline not
  checked yet; uncommitted changes in the checkout.

## Open questions

- Repo identity: should a fresh clone of the same repo pick up the old state, or start over?
- Repos with several apps or platforms: one config with several test commands, or one per product?
- How to keep landing fast when a full `xcodebuild test` takes many minutes: affected tests only, or
  batching (doc 08 §6)?
- Where do findings go when the tracker is a real one: a ticket per blocker, or only the app's pane?
