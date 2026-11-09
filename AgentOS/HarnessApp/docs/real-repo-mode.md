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

**Not in scope yet:** shared or cloud storage, more than one user. Following `main`, pushing or opening pull
requests, and several repos forming one system are planned (phases 8, 9 and 10).

## How it's used

1. **Open Repository…** and choose a git repo.
2. The **readiness scan** runs and shows its findings. Blockers must be fixed before work can start;
   warnings can be accepted.
3. The scan **drafts a repo config** from what it found: how to build and test, components, test
   locations. You review it, and it only counts once it's committed on `main`.
4. Tickets come from the tracker the repo config names (`tracker`): **GitHub Issues**, or without one the
   app's **local tracker** (the simulator's tracker pane, persisted).
5. From here it's the simulator's flow, on real code: preview → breakdown → tests → build → pre-check →
   landing queue → proven.
6. Proven work lands on the local branch **`agentos/main`**. You review, merge and push it yourself.

## What changes compared to the simulator

| | Simulator | Real repo |
|---|---|---|
| Repo | Created by the harness, `Package.swift` generated | Exists. The harness never restructures it, so it must **discover** how it's built |
| Build and test | `swift test`, hard-coded | Commands from the repo config, e.g. `xcodebuild test -scheme App -destination 'platform=iOS Simulator,name=iPhone 14,OS=18.6'` |
| A leaf's tests | A new test target per leaf | Files in an **existing** test target, in the leaf's own folder `<leafTests.folder>/<suite>`, as a suite named after the leaf (e.g. `WORK_1Tests`), run with `test.only` (e.g. `-only-testing:`; XCTest and Swift Testing). The protected-tests fingerprint covers that folder |
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

Following doc 04 §8, the app's own **harness settings** (the Settings window) set the outer limits, and the
repo's **`.agentos/config.json`** may only choose within them or make them stricter. The repo config is
read from `main` only.

| Setting | Harness default (limit) | Repo may |
|---|---|---|
| Landing target | Local branch `agentos/main` | Choose another *local* branch name |
| Push / open pull requests | Never (phase 9: an opt-in setting; only the harness pushes, never agents) | Switch it off |
| Agent tools | Copilot CLI, with `git push`/`fetch`/`pull`/`remote`/`config`/`stash`, `gh` and network installs denied | Deny more |
| Agent models | Offered models, plus a default model per role (breakdown, acceptance tests, implementation); none = the CLI's default | Pick a model per role among the offered ones |
| Max attempts / reworks per leaf | 3 / 3 | Lower |
| Max parallel agents | 2 | Lower |
| Guesswork | `assume and report`: carry on and post assumptions; a leaf whose work rests on assumptions waits for a person to see its acceptance tests before build, even under `harness:go`. Guesses about what users observe (what to check, which screen, which behaviour) always stop the node; guesses about implementation don't. Other levels: `ask` (assumptions are questions too), `autonomous` (assumptions are posted, nothing waits) | Choose a stricter level (`agents.guesswork`) |
| Signals people may use (doc 05 §3) | All, including `harness:go` | Switch some off, e.g. `go` to force a breakdown review |
| Required checks | Build + the leaf's tests on branch; all tests at landing | Add more (lint, snapshot tests…) |
| Protected paths | Tests of proven leaves, `.agentos/`, AGENTS.md, CONTRIBUTING, CODEOWNERS, copilot-instructions | Add more |

The policy pane shows every effective value with its source (*harness*, *repo*). A repo value that tries to
loosen a limit becomes a blocker finding, not a silent override, and the harness's value applies. So does
landing directly on the default branch. Disabling a signal the harness doesn't know is a warning.

The repo config is the manifest from doc 01 in a simple form. It's JSON, so the app needs no extra parser;
unknown keys are reported as likely typos. For an iOS app:

```json
{
  "build": { "prepare": "xcodegen generate" },
  "test": {
    "command": "xcodebuild test -scheme App -destination 'platform=iOS Simulator,name=iPhone 14,OS=18.6'",
    "only": "-only-testing:AppTests/{suite}"
  },
  "checks": [{ "name": "lint", "command": "swiftlint --strict" }],
  "leafTests": { "target": "AppTests", "folder": "AppTests/Acceptance" },
  "components": ["App/Features/Weather", "App/Services", "Packages/Networking"],
  "landing": { "branch": "agentos/main" },
  "signals": { "disable": ["go"] },
  "limits": { "maxAttempts": 2 },
  "agents": { "deny": ["rm -rf"], "models": { "implementer": "claude-sonnet-4.5" } },
  "protectedPaths": ["App/Secrets/"],
  "tracker": { "type": "github-issues", "repo": "owner/name",
               "project": { "owner": "owner", "number": 1, "statusMap": { "Landing": "Done" } } }
}
```

Only `test.command` is required to scan and run the baseline; agents also need `leafTests` (where a leaf's
acceptance tests go; missing = blocker) and should have `test.only` (missing = warning: every leaf then runs
all tests). Checks run in order (prepare, build, test, then `checks`) with `/bin/sh -c`
from the repo's top folder, and stop at the first failure. `{suite}` in `test.only` is replaced with a
leaf's suite, so a leaf runs only its own tests; the extra checks run at landing.

When the repo has no config, the scan **drafts** one from what it found and shows it with a Copy button
(also printed by `agentos scan`). In the Policy pane, **Create** writes the draft into your checkout and
opens it; with a config, **Open** opens the checkout's copy. You commit it yourself: the config steers the
harness, so the harness never commits it and agents never edit it (see Safety).

## Readiness scan for an Xcode repo

| Check | Severity if it fails |
|---|---|
| It's a git repo with at least one commit; the default branch is found | Blocker |
| The default branch has a local copy (otherwise `origin/<branch>` is read, with its last fetch date) | Info |
| A repo config exists, can be read, and doesn't loosen any harness limit | Blocker |
| **Tests pass on `main`** at its current commit (the baseline) | Blocker |
| AGENTS.md or copilot-instructions exist and say how to build and test | Warning |
| README explains what this is; CONTRIBUTING has a Definition of Done | Warning |
| No `project.pbxproj` hotspot (see above). Info if the config's prepare step regenerates the project | Warning |
| A test target for acceptance tests exists; the test framework is known | Warning |
| The simulators the config's commands name are installed | Warning |
| The config has no unknown keys; there's no other `.agentos/config*` file | Warning |
| CODEOWNERS covers the files that steer agents | Info (Warning for stricter profiles) |
| Uncommitted changes in your checkout | Info: the harness works from `main` and won't include them |
| The config's tracker can be used: a known type, a GitHub repo (`tracker.repo` or `origin`), `gh` installed | Blocker |
| The config's board (`tracker.project`) can be read and has an option for each mapped status | Warning: the status shows as a label instead |

Findings appear in their own pane and are recorded in the ledger. New findings during work (a flaky
test, a leaf touching files outside its touch set, repeated reworks on the same file) appear there too.

### The baseline

The baseline runs the config's checks on a clean export of `main` (`git archive` into the harness's own
storage), so neither your checkout nor the repo's build folders are touched. Its result and log are
recorded in the ledger as evidence. It belongs to a commit: once `main` moves, the scan asks for it again.

## Storage

The harness's state for a repo is private and lives outside the repo:

```
~/Library/Application Support/AgentOS/repos/<repo-id>/
  ledger.jsonl     events, hash-chained
  tracker.json     local tracker tickets (when no tracker adapter is configured)
  artifacts/       check logs (evidence), e.g. baseline-<commit>.log, and each agent run's own log,
                   <node>-<run>-agent.log, written as it runs
  baseline/src/    the export of main the baseline last ran on
  worktrees/       one working copy per leaf, on branch agentos/leaf/<node>
  exclude          files git ignores in worktrees (.build/, DerivedData/, xcuserdata/, .DS_Store…)
```

`<repo-id>` is derived from the repo's first commit plus its path, so two clones of the same repo don't
share state by accident.

Code talks to storage through small protocols, with file-based adapters first:
- `LedgerStore`: append records; read all records. The ledger itself checks node versions
  (compare-and-swap) before it appends.
- `TicketStore`: the local tracker's tickets.
- `ArtifactStore`: put a file, get its path and checksum; or get a file to write to as it grows (agent logs).

SQLite and server-based adapters can be added later without touching the reconciler.

## The workspace

A `RepositorySession` runs the simulator's reconciler on the repo: its `RepositoryWorkspace`, the
config-driven checks, the local tracker (project key `WORK`) and the repo's ledger.

- **Worktrees.** Each leaf gets a git worktree in the harness's storage, on its own branch
  `agentos/leaf/<node>`, started from the landing branch. The landing branch is created from the default
  branch the first time. Git runs with the harness's own exclude file, so build output is never committed
  even if the repo's `.gitignore` misses it. Uncommitted leftovers (e.g. a regenerated project file) are
  discarded before a rebase or rework.
- **Agents** get the repo's context in their prompt: the configured commands, where their tests go, and the
  protected paths. The test author may only add files in the leaf's own test folder; anything else fails
  the run.
- **Checks** before landing: the leaf's tests are unchanged since they were approved, no other leaf's tests
  changed, and no protected path changed. Then the leaf's tests (`test.only`), then all checks at landing.
- **Landing** is a fast-forward of the landing branch with `git update-ref` (compare-and-swap), so no checkout
  is involved. It's refused while any checkout has the landing branch checked out, because moving it there
  would make that working copy look modified.
- **Copilot agents** run with `--allow-all-tools` plus a `--deny-tool` per effective denied tool (network
  installs as one `shell(…)` pattern) and per protected file (`write(AGENTS.md)`), and `--model` per role.
  Copilot's `write()` patterns only cover file names; folders and globs are enforced by the check above.
- **Your git state** is fingerprinted before and compared after each test-author and implementer run: refs
  outside `agentos/` (tags, remote-tracking refs, the stash; for local branches only whether they exist,
  since you may commit while agents work), and the shared git config, hooks and `info/` files. Worktrees
  share all of these with your repo. Any change escalates the leaf instead of retrying it, naming what
  changed; if it was you (e.g. you fetched meanwhile), add `harness:retry`. When agents ran side by side,
  the change can't be pinned on one: each of them is escalated and names the others it ran with.
- **Parallel work.** Each round, up to *max parallel agents* nodes take their step at the same time
  (breakdown, tests, build, pre-check), each in its own worktree; landing stays one at a time. The limit
  counts the agents the harness starts, not the sub-agents they use. Adding and removing worktrees is
  serialized, because they share the repo's `.git`. Running side by side costs no more agent work than one
  after the other, except that leaves built from the same landing branch conflict more often at landing,
  and a conflict means rework.
- **Simulators.** A check whose command names a simulator (`-destination '…Simulator,name=…'`) borrows one
  of the harness's own copies of it: same model and OS, named `AgentOS <model> (<OS>) <n>`, one per
  parallel agent, made with `simctl create` the first time and reused after. Your own simulator is left
  alone. Checks that name no simulator (e.g. `swift test` on a package) don't wait for one. If no copies
  can be made, checks use the configured simulator, one at a time. Remove the copies in Xcode → Devices and
  Simulators.
- **Watching agents work.** The window refreshes on every ledger event (a run starting, a submission,
  evidence), not only after a round. *Running now*, above the work tree, lists each run under way with its
  role and time so far, and offers:
  - **Log**: the agent's output, followed live. Copilot writes each step as it goes (only the decomposer
    runs with `-s`, since its answer is parsed). The file is kept, and the node's details list every agent
    run with its log. Checks have no live log; theirs is recorded as evidence when they finish.
  - **Changes**: what the worktree changed since it left the landing branch, committed or not, including new
    files. Read with `git --no-optional-locks`, so looking never takes the index lock from an agent.
  - **Finder** and **Xcode**: the worktree itself. Look, don't change: anything changed there is committed
    as the agent's work.

Known limits: a leaf's tests go in the one configured test target, so if that target needs a simulator,
every leaf's checks do; picking a target per leaf (e.g. a package's tests for service-layer work) would
let those skip it. Tickets blocked by another system never unblock (there's no external system adapter
yet).

`agentos work [<repo>] [--ticket <title> --criterion <text>… --go]` runs it from the terminal until nothing
more can happen without a human. In the app, the repository window shows the tracker and work tree next to
the findings, policy and ledger, with Step and Run once nothing blocks agents.

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

The harness does write to the repo, but only in one place: it moves its landing branch (and keeps
worktrees for it). Three rules bound that:

- **Your checkout and `main` are never changed.** Your working copy may hold uncommitted work and be open
  in Xcode; writing there would clobber it. Agents work in worktrees outside the repo folder, and you merge
  `agentos/main` into `main` yourself. Nothing is pushed.
- **The harness never edits the files that steer it** (`.agentos/`, AGENTS.md, CONTRIBUTING, CODEOWNERS,
  copilot-instructions). They set its limits, so a harness that could edit them could loosen its own
  policy. They're read from `main` only, and a leaf that changes them fails its check, like changing
  someone else's tests. A suggested config is shown for you to commit.
- **Code only arrives through the landing branch, with evidence.** Any other write would skip the checks
  and the ledger.

Agent processes also get a clean environment and restricted tools (see the workspace's denied tools), and a
run that changes your refs or git config anyway is escalated. Branch refs and worktree records do live in
the repo's `.git`. Removing the `agentos/` branches and the harness's storage removes every trace of it.

The harness itself never fetches or creates your branches. If the remote's default branch (`origin/HEAD`)
has no local copy, the scan, baseline and landing read **`origin/<branch>`** as of your last fetch; the
scan shows when that was and suggests `git fetch` or `git branch <branch> origin/<branch>`. The landing
branch is created with `--no-track`, so no upstream is written to your config.

Denied tools are a speed bump, not a wall: agents run as you, with your SSH agent and `gh` login, so a
determined agent could still reach the remote by other means. The git state check catches the local
traces; running agents without your credentials (a sandbox or separate user) is future work.

## Phases

Each phase is usable on its own.

1. **Package split and storage protocols.** File adapters; rename the folder. The simulator behaves exactly
   as before. *Done.*
2. **Readiness scan and findings pane.** Read-only, so it's safe to run on any repo. Pilot: this repo. *Done:*
   File → Open Repository…, `agentos scan`. Checking simulators and SDKs waits for the configured test
   command (phase 3).
3. **Repo config and policy layers.** Settings pane with sources; a check runner driven by the config;
   baseline check on `main`. *Done:* `.agentos/config.json`, Settings window (harness limits), policy pane
   (effective values with source, checks, baseline, draft config), `agentos baseline [--config <file>]`.
   The reconciler doesn't run on real repos yet, so the effective policy is shown but not yet enforced.
4. **Real workspace.** Worktrees outside the repo, a leaf's tests in an existing target, landing on
   `agentos/main`, Copilot agents with restricted tools. Agents follow the two policy layers: the harness
   settings name the providers and models on offer, plus a default model per role (breakdown, tests,
   implementation); the repo's `agents` section may only pick among those and deny more tools. The
   policy pane shows each role's agent and model with its source, and the effective denied tools are
   passed to the agent (`--deny-tool`) instead of allowing all tools. *Done:* see The workspace;
   `agentos work`; Step / Run in the repository window; agent models in Settings.
5. **Parallel agents.** Up to *max parallel agents* nodes at a time, worktree setup serialized, a pool of
   the harness's own simulators for checks that need one, and the git state check naming the agents that
   ran together; and watching it happen: live refresh, the runs under way with their live logs, changes so
   far and worktree. *Done:* see The workspace.
6. **Clarifying questions.** Agents say what they're unsure of instead of guessing (doc 05: open questions
   and assumptions; doc 00: when unsure, escalate). Found on this repo: WORK-3 was a one-line ticket
   without acceptance criteria, became a leaf at once, and its test author guessed the wrong view.
   - **Ready check before breakdown:** a ticket without acceptance criteria, or too vague to test, isn't
     started; the harness comments with what's missing.
   - **Questions and assumptions from every agent:** the decomposer and test author return them with their
     result, recorded in the ledger. An open question stops that node (`needs input` flag, the questions
     on the ticket and in the attention list); the answer on the ticket plus `harness:retry` continues it.
     Assumptions are posted on the ticket.
   - **How much guessing is allowed**, a policy setting (see Policy).
   - **The build gate shows what it approves:** `harness:go` comes after the leaf's acceptance tests and
     assumptions are visible, since the tests are where intent gets fixed. The test author is told to
     test behaviour, not source text.

   *Done:*
   - The decomposer first checks the ticket is ready ("could someone test each criterion without guessing
     what users observe?") and answers with questions instead of children when it isn't. A preview with
     questions records nothing; you edit the ticket and preview again.
   - The decomposer and test author return questions and assumptions with their result. Questions write
     `questionsRaised` and the `needs input` flag, and post a "❓ Needs input" comment with them. Tests
     written on a guess are thrown away. You answer in comments, then add `harness:retry`; without a
     comment after the question it's refused. The answer is recorded (`questionsAnswered`) and every agent
     working on the node or below it gets it as data.
   - Every leaf's tests are posted when written: files, test names and the assumptions the work rests on.
     Under `assume and report`, a leaf with assumptions waits (`needs input`). `harness:build` (or `go`)
     approves its tests as they are; a comment plus `harness:retry` has them written again with your
     feedback. Accepting a preview accepts its assumptions.
   - The Copilot test author reports in `.agentos-report.json`, which the harness reads and removes before
     the commit. Simulation hints `sim:ask` and `sim:assume`; a criterion ending in "?" makes the scripted
     decomposer ask.
   - Guesswork in Settings and in the repo config (`agents.guesswork`); a looser value is a blocker.
7. **GitHub Issues adapter**, as the first real tracker.

   *Done:*
   - `"tracker": { "type": "github-issues" }` in the repo config; `repo` defaults to the `origin` remote.
     The scan reports which tracker is used, and blocks when it can't be (unknown type, no GitHub repo, no
     `gh`).
   - Issues are tickets keyed `GH-<number>`; pull requests are left out. Acceptance criteria are the list
     under an "Acceptance criteria" heading (bullets, numbers or task list); `Blocked by:` and `Parent: #n`
     lines carry the links. Child issues are also linked as GitHub sub-issues where available.
   - An issue form, `.github/ISSUE_TEMPLATE/agentos-ticket.yml` (in this repo; copy it to yours), has
     separate Description, Acceptance criteria and Blocked by fields. The parser reads the sections GitHub
     makes from them (`### …` headings, `_No response_` for empty fields, `#12` meaning `GH-12`).
   - Signals are `harness:` labels, created in the repo on first use. Who set a label comes from the issue's
     events, so only people's labels count, as before. The status is an `agentos: <status>` label.
   - The harness talks to GitHub through `gh api` with your login, or the account set in Settings
     (*GitHub account*; `--github-account` for `agentos work`). Agents never get the token. Since it acts as
     you, everything it writes carries a hidden `<!-- agentos -->` marker, which is how its comments and
     issues are told apart from yours.
   - Polling, kept small: open issues at most every 10 seconds and after the harness's own changes;
     comments and label events only when an issue changed. Failed requests show in the activity log.
   - A tracker that refuses a child ticket escalates the breakdown; `harness:retry` creates the rest.
   - **`harness:replan`** redoes an adopted ticket's plan from the ticket as it is now, e.g. after you
     changed its criteria or added a forgotten `Blocked by`. It works on the top ticket (not on its children)
     until building starts below it. The ticket keeps the answers given to questions; nothing is approved
     afterwards: preview, breakdown or go again. Its child tickets wait, paused, for that breakdown, which
     compares itself with the old one: children it contains unchanged (same title, intent and criteria) are
     kept, with their tickets, acceptance tests and approvals, and take any new dependencies. The others are
     closed as *not planned* with a comment (with the local tracker, status *Superseded*), and signals on them
     are refused.
   - **Dependencies between tickets.** `Blocked by: #12` on a ticket waits until `GH-12` is proven here. On
     a ticket that's broken down, it holds every leaf unless the breakdown gave that dependency to particular
     leaves.
   - **Projects board (opt-in).** With `tracker.project` (owner, number, optional `statusField` and
     `statusMap`), the board's Status field follows the harness: Specifying and Breaking down → Backlog,
     Ready, In progress, In review (checking and landing), Done. Issues not on the board are added.
     Statuses needing attention (Needs input, Needs human, Blocked) have no option by default: they stay
     `agentos:` labels and the card stays where it was. A `statusMap` entry overrides a default; `""`
     leaves the board alone for that status. One way only: moving a card never asks the harness for
     anything. Uses GraphQL and needs the `project` scope (`gh auth refresh -s project`); the scan warns
     when the board can't be read or lacks options, and an unreadable board is tried again every 5 minutes,
     with labels meanwhile.
   - Not yet: webhooks, ETags and rate-limit back-off; closing issues (the status says *Done*).
8. **Catching up with `main`.** Today `agentos/main` is created from `main` once and never follows it, so
   your later commits never reach the agents. When `main` moves and its baseline passes, the harness
   rebases `agentos/main` onto it (or merges, if rebasing would rewrite landed work you've already
   merged). Leaves in progress then rebase as usual; conflicts go to rework, as at landing. Nothing is
   fetched: `main` is whatever your clone has.
9. **Publishing pull requests.** The way out to the world, and the end state of concept docs 04 and 08 (every
   change a reviewed pull request). One pull request per **requirement** (a top-level ticket, or a
   composite node), opened once all its leaves are proven; single leaves are too small to review on their
   own. The **harness** pushes the branch (e.g. `agentos/WORK-1`) and opens the pull request; agents keep
   `git push` and `gh` denied. The description carries the requirement, its breakdown, which tests prove
   which acceptance criteria and the check results, with links to the evidence. With phase 7 the pull
   request links to its issue, and the issue follows the pull request's state. Governed by *Push / open
   pull requests*: the harness setting allows it (off by default), the repo may only switch it off.
   Later, in production, each leaf goes through the remote's merge queue with CI as the check runner,
   replacing the local `agentos/main` (doc 08).
10. **Several repos, one system.** Until now one repo is one system: one ledger and work tree per repo,
   components are parts of it, and other systems appear only as external dependencies. Here a system
   spans repos, possibly in different source control systems: the ledger and work tree belong to the
   system, and each node names the repo it lives in. Each repo keeps its own workspace, config, checks,
   policy and landing branch. **Integration nodes** (composites spanning repos) are proven by checks
   across them, such as contract or end-to-end tests, once their children have landed in their own repos.
   With phase 9, one requirement can become pull requests in several repos. Also covers the reverse case:
   several apps in one repo, as separate systems.

## Pilot: this repo

The first repo to try is this one (`agent-harness-os`). The first scan (phase 2) found what was expected:
- Blocker: no repo config. Only one test entry point was found (`swift test` in `AgentOSKit`), because
  the app target has no tests.
- Warnings: no AGENTS.md or copilot-instructions; no CONTRIBUTING; `project.pbxproj` is generated by
  XcodeGen but committed (hotspot); the app target has no test target.
- Info: Swift package `AgentOSKit` using Swift Testing; the XcodeGen project; no CODEOWNERS; baseline not
  checked yet; uncommitted changes in the checkout.

Phase 3: the scan drafted a config with `xcodegen generate` as the prepare step, `swift test` in
`AgentOSKit` as the test command (`--filter {suite}` for a leaf), and an `xcodebuild build` of the app as an
extra check. Tried uncommitted with `agentos baseline --config .agentos/config.json`: it passed on `main` in
44 seconds, running `main`'s tests rather than the working copy's.

Phase 4: with `leafTests` in the config (leaf suites go in `AgentOSAdaptersTests`), the scan's only blocker
was a baseline for the new `main` commit. With that, `agentos work` starts a session and creates
`agentos/main`, leaving the checkout untouched. A first baseline run failed once on a flaky simulator test
(`contradictingWorkIsEscalatedAsARequirementsConflict`) and passed when run again. A real Copilot run on
this repo hasn't been done yet.

## Open questions

- Repo identity: should a fresh clone of the same repo pick up the old state, or start over?
- Repos with several apps or platforms: one config with several test commands, or one per product?
- How to keep landing fast when a full `xcodebuild test` takes many minutes: affected tests only, or
  batching (doc 08 §6)?
- Where do findings go when the tracker is a real one: a ticket per blocker, or only the app's pane?
