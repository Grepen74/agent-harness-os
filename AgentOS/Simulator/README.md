# AgentOS Simulator

A small, working model of the agent harness described in docs [00](../../00-overview.md)–[08](../../08-leaves-and-parallel-work.md).
It is not a production design. The point is to make the concepts concrete enough to try out, question and
change. The code is kept as simple as the concepts allow. Comments marked *Production:* say what a real
system would need on top.

It simulates the whole loop:

```
 Tracker (humans)  ──labels──▶  Reconciler (harness loop)  ──events──▶  Ledger (hash-chained JSONL)
       ▲                           │        │                                │
       └──── comments, statuses ───┘        ├─▶ Agents (scripted or Copilot CLI), one git branch per leaf
                                            ├─▶ Checks: real `swift test` → evidence + log artifacts
                                            ├─▶ Landing queue: rebase → all tests → merge to main
 Other team's system ──delivered──▶  ───────┘   (an external dependency you resolve by hand)
```

The product is one git monorepo (`workspace/repo`): each folder in `Sources/` is a component (module), each
folder in `Tests/` is one leaf's acceptance tests. `Package.swift` is generated from the folders and never
committed. Every leaf works on its own branch in its own working copy (`workspace/worktrees/<node>`) and
may touch several components (a vertical slice, doc 08 §1).

## Run it

```bash
cd AgentOS/Simulator
swift run AgentOSSimulator          # the Mac app
swift run agentos demo              # the whole flow in the terminal, human steps scripted
swift test                          # rules and flows, with a fast fake check runner
```

You can also open `Package.swift` in Xcode and run the `AgentOSSimulator` scheme. This package is separate
from the `AgentOS` Xcode project next to it. The app keeps its data in
`~/Library/Application Support/AgentOSSimulator`. The CLI uses a temporary folder unless you pass `--dir`.

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
   to act (safe stop).

More things to try:
- On a leaf ticket, add `sim:always-fail` before building. After repeated failures it escalates to
  *Needs human*. Remove the label, then add `harness:retry`.
- Use `sim:fail-once` to see a failure followed by a recovery, or `sim:stuck` for an agent that crashes.
- Choose **⚙︎ → Restart harness** while it is running. State reloads from the ledger and unfinished runs
  are reclaimed.
- Switch **Agents** to *Copilot CLI* to have real agents decompose the work, write tests and implement.
  This is slow and uses your Copilot quota.
- Open the workspace in Finder to inspect the repo, the leaves' working copies and the check logs
  (`artifacts/`). `git log` in `workspace/repo` shows every landed commit, authored by the run that built it.

## Where the concepts live

| Concept (doc) | Code |
|---|---|
| Work Node, phases, gates, flags, typed links (02, 00 §typed links) | `Model/Model.swift`, `Ledger/WorkingState.swift` |
| Ledger: append-only, hash chain, compare-and-swap, idempotent (04 §7) | `Ledger/Ledger.swift`, `Ledger/LedgerEvent.swift` |
| Tracker adapter: signals in; comments and statuses out (03, 05) | `Tracker/` |
| Deliberate signals, preview ("what you saw is what you get"), readiness (05) | `Reconciler/Reconciler.swift` (intake), `Reconciler/Policy.swift` |
| Reconciler round, one step per node, safe stop, restart recovery (07) | `Reconciler/Reconciler.swift` |
| Builder ≠ checker; locked acceptance tests; evidence pinned to a commit (02, 04, 08 §2) | `Reconciler.preCheck`, `Reconciler.land`, `Ledger.validate` |
| Vertical-slice leaves with a touch set; one test target per leaf (08 §1–2) | `NodeSpec.touches`, `NodeSpec.testTarget`, `Planner.childSpecs` |
| Branch per leaf, parallel build, optimistic landing queue (08 §4) | `Workspace/Workspace.swift`, `Reconciler.land`, `WorkingState.landingQueue` |
| Rework on merge conflict; requirements conflict → human (08 §5) | `Reconciler.land`, `Policy.maxReworks` |
| Escalation: attempt limit and the no-progress rule (02 §7) | `Policy.escalationReason` |
| External dependency in another system (03) | `External/MockExternalSystem.swift` |
| Observability: tree, attention list, ledger log (06) | `Sources/AgentOSSimulator/` |

## Deliberate simplifications

- One process, with steps run one after another. There is no leader election or fencing. Leaves are still
  "parallel" where it matters for conflicts: each starts from the `main` of its time on its own branch.
- One repo and one profile, so the tree is always two levels (an epic and its leaves) and there are no
  integration nodes or recursive leaf check. Going up the V is: the epic is proven when all leaves landed.
- No touch-set scheduling (doc 08 §4 layer 1), no batching in the landing queue, no leases.
- The scripted agents "implement" by writing each criterion as a *fact* in every component they touch
  (`"temperature unit": "Celsius"`). That's trivial, but it causes real merge conflicts and real
  regressions, and the checks are real `swift test` runs.
- No spec changes: a requirements conflict stays escalated. In production a human edits one of the
  tickets, which re-plans the affected nodes.
- One policy profile. No security or safety profiles, and no human review gate before merge.
- The ledger is a local JSONL file. Production would use a database and external anchoring (doc 04 §7).
