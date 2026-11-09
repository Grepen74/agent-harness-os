# AgentOS Harness app

A Mac app for the agent harness. It has two kinds of window:
- the **simulator** (below), and
- **repository windows** for real repos (File → Open Repository…). These run the read-only readiness
  scan, show the effective policy, run the baseline and, once nothing blocks it, let Copilot agents work
  on tickets from a local tracker, landing proven work on the local branch `agentos/main`
  ([design](docs/real-repo-mode.md)).

## The simulator

A small, working model of the agent harness described in docs [00](../../00-overview.md)–[08](../../08-leaves-and-parallel-work.md).
It is not a production design. The point is to make the concepts concrete enough to try out, question and
change. You play the humans (and the other team); the harness and its agents do the rest.

It simulates the whole loop:

```
 Tracker (humans)  ──labels──▶  Reconciler (harness loop)  ──events──▶  Ledger (hash-chained JSONL)
       ▲                           │        │                                │
       └──── comments, statuses ───┘        ├─▶ Agents (scripted or Copilot CLI), one git branch per leaf
                                            ├─▶ Checks: real `swift test` → evidence + log artifacts
                                            ├─▶ Landing queue: rebase → all tests → merge to main
 Other team's system ──delivered──▶  ───────┘   (an external dependency you resolve by hand)
```

## Layout

| Path | What |
|---|---|
| `AgentOSHarness.xcodeproj` | The Mac app. Generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`xcodegen generate`); the generated project is committed. |
| `App/` | The app target: windows, toolbar, the other team's system, `SimulatorModel` (runs the simulation behind the shared panes) and `RepositoryModel` (a real repo). |
| [`docs/`](docs) | App design docs, e.g. [running the harness on a real repo](docs/real-repo-mode.md). |
| [`AgentOSKit/`](AgentOSKit) | The harness as a Swift package (Core, Adapters, Simulation, UI), with a terminal demo and tests. See its [README](AgentOSKit/README.md) for how it works and where each concept lives in code. |

## Run it

Open `AgentOSHarness.xcodeproj` and run the **AgentOSHarness** scheme. It opens with a welcome window:
open a repo (or a recent one), or **Show Simulator** (⇧⌘N). No Xcode? Run the same flow in the terminal:
`cd AgentOSKit && swift run agentos demo`.

- The app keeps its data in `~/Library/Application Support/AgentOSSimulator`. **⚙︎ → Reset everything**
  starts over.
- It is not sandboxed on purpose: the harness runs `git`, `swift test` and the Copilot CLI as child
  processes. It is signed to run locally only.
- **Step** runs one reconciler round; **Run** runs one round a second, like the always-on service.

## Open a real repo

**File → Open Repository…** (⌘O) and choose a git repo. The window runs the **readiness scan** (doc 01)
and lists its findings: blockers must be fixed before agents may work there, warnings can be accepted.
**File → Show Simulator** (⇧⌘N) opens the simulator; it's only created when you first open it.

- The scan is read-only. It reads the default branch through git and never touches your working copy.
- Each scan is recorded in that repo's own ledger, outside the repo, in
  `~/Library/Application Support/AgentOS/repos/<repo>-<id>/`. A rescan that finds nothing new isn't recorded.
- To open a repo straight from Xcode, add `-openRepository <path>` to the scheme's launch arguments.
- The same scan runs in the terminal: `cd AgentOSKit && swift run agentos scan <path>`.

The **Policy** pane shows what applies to the repo: the harness's limits from **Settings** (⌘,), tightened
by the repo's `.agentos/config.json`, each value with its source. The config says how to build and test.
If the repo has none, the pane shows a draft guessed from the scan; check it, then commit it on `main`
yourself. The harness never changes your checkout or `main`, and never edits the files that steer it
(the config, AGENTS.md, CONTRIBUTING, CODEOWNERS): otherwise it could raise its own limits.

With a config, **Run baseline** runs its checks on a clean export of `main`, outside your checkout, and
records the result and log in the ledger. Agents may only start once the baseline passes at `main`'s
current commit. To try a config before committing it: `swift run agentos baseline <path> --config <file>`.

Once nothing blocks agents (the toolbar says why if something does), work happens like in the simulator:
create a ticket in the **tracker** pane, add `harness:breakdown`, `harness:build` or `harness:go`, then
**Step** or **Run**. The tracker is private to this Mac (stored with the ledger), unless the repo config
says `"tracker": { "type": "github-issues" }`: then tickets are the repo's GitHub issues, read and written
with your `gh` login (Settings → *GitHub account* picks another). Add `"project": { "owner": …, "number": … }`
and a Projects board's Status field follows the work too. Each leaf is built by
Copilot CLI in its own git worktree outside the repo; its acceptance tests go in the config's `leafTests`
folder. Proven work lands on `agentos/main`; review, merge and push it yourself. **Settings** picks the
models offered to agents and a default per role; a repo may choose among them in `agents.models`. From the
terminal: `swift run agentos work <path> --ticket "<title>" --criterion "<criterion>" --go`.

## Try this in the app

1. **⚙︎ → Load demo tickets.** Press **Step** or **Run**: nothing happens. Tickets need a deliberate signal (doc 05).
2. On **APP-2 Dark mode**, add `harness:preview`. It is rejected with an explanation because it has no
   acceptance criteria (the Definition of Ready). Edit the ticket and try again.
3. On **APP-1 Weather widget**, add `harness:preview`. The proposed tree is posted as a comment.
   Nothing is created.
4. Add `harness:breakdown`. Child tickets appear, built from exactly the tree you previewed. Each leaf
   gets its own branch, and a test-author agent commits its acceptance tests there first.
5. Add `harness:build`. The first two leaves are built in parallel from the same `main` and both create
   `WeatherUI`. The first lands; the second hits a merge conflict in the landing queue and is **reworked**
   on the latest `main` (♻️ in the tree; not counted as a failure), then lands. The third is **Blocked**
   because it waits for `BACKEND-42`.
6. **⚙︎ → Add contradicting ticket (Fahrenheit)**, then add `harness:breakdown` and `harness:build` to it.
   Its Fahrenheit leaf merges cleanly, but breaks APP-1's proven Celsius test, so the landing queue
   escalates a **requirements conflict** instead of merging. Its other leaf lands normally.
7. In *Other team's system*, click **Mark delivered**. The leaf unblocks, conflicts once on
   `WeatherService`, is reworked and lands. The epic becomes **Proven** once all its leaves have landed.
8. Click **Verify chain**, then **Tamper (demo)**. The ledger now fails its check and the harness refuses
   to act (safe stop). **Restore backup** puts back the copy saved before the tamper and restarts the
   harness; press Run to continue.

More things to try:
- Create a ticket and add `harness:go`: it is broken down, built and checked in one go, with no stop
  between breakdown and build.
- On a leaf ticket, add `sim:always-fail` before building. After repeated failures it escalates to
  *Needs human*. Remove the label, then add `harness:retry`.
- Use `sim:fail-once` to see a failure followed by a recovery, or `sim:stuck` for an agent that crashes.
- Clarifying questions: an acceptance criterion ending in "?" makes the decomposer ask instead of guessing,
  and `sim:ask` makes the test author ask. The node shows *Needs input*; answer in a comment, then add
  `harness:retry`. With `sim:assume` the test author reports an assumption, so the leaf waits for you to
  look at its tests: `harness:build` approves them, a comment plus `harness:retry` has them rewritten.
- Choose **⚙︎ → Restart harness** while it is running. State reloads from the ledger and unfinished runs
  are reclaimed.
- Switch **Agents** to *Copilot CLI* to have real agents decompose the work, write tests and implement.
  This is slow and uses your Copilot quota.
- Open the workspace in Finder to inspect the repo, the leaves' working copies and the check logs
  (`artifacts/`). `git log` in `workspace/repo` shows every landed commit, authored by the run that built it.
