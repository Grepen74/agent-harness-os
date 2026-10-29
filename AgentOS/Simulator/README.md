# AgentOS Simulator

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
| `AgentOSSimulator.xcodeproj` | The Mac app. Generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`xcodegen generate`); the generated project is committed. |
| `App/` | The app's SwiftUI sources: tracker, work tree and ledger panes. It only displays state and sends human signals. |
| [`docs/`](docs) | App design docs, e.g. [running the harness on a real repo](docs/real-repo-mode.md) (proposal). |
| [`AgentOSCore/`](AgentOSCore) | The harness itself as a Swift package, with a terminal demo and tests. See its [README](AgentOSCore/README.md) for how it works and where each concept lives in code. |

## Run it

Open `AgentOSSimulator.xcodeproj` and run the **AgentOSSimulator** scheme. No Xcode? Run the same flow in
the terminal: `cd AgentOSCore && swift run agentos demo`.

- The app keeps its data in `~/Library/Application Support/AgentOSSimulator`. **⚙︎ → Reset everything**
  starts over.
- It is not sandboxed on purpose: the harness runs `git`, `swift test` and the Copilot CLI as child
  processes. It is signed to run locally only.
- **Step** runs one reconciler round; **Run** runs one round a second, like the always-on service.

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
- Choose **⚙︎ → Restart harness** while it is running. State reloads from the ledger and unfinished runs
  are reclaimed.
- Switch **Agents** to *Copilot CLI* to have real agents decompose the work, write tests and implement.
  This is slow and uses your Copilot quota.
- Open the workspace in Finder to inspect the repo, the leaves' working copies and the check logs
  (`artifacts/`). `git log` in `workspace/repo` shows every landed commit, authored by the run that built it.
