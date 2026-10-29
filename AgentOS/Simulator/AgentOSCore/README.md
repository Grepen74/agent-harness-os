# AgentOSCore

The harness from the [AgentOS Simulator](../README.md) as a Swift package, without UI. The code is kept as
simple as the concepts allow. Comments marked *Production:* say what a real system would need on top.

| Target | What |
|---|---|
| `AgentOSCore` (library) | Ledger, reconciler, tracker adapter, agents, workspace and checks. `Simulation` wires them together. |
| `agentos` (executable) | Runs the whole demo in the terminal, with the human steps scripted. |
| `AgentOSCoreTests` | The rules and flows, with a fast fake check runner (Swift Testing). |

```bash
swift run agentos demo [--agents scripted|copilot] [--dir <path>] [--keep]
swift run agentos tree|verify --dir <path>
swift test
```

The demo exits with 0 only if the epic is proven, a merge conflict was reworked, the contradicting
requirement was escalated and the ledger chain is intact. It uses a temporary folder unless you pass `--dir`.

## How it works

The agents build a *product*: one git monorepo the harness creates in its data folder (`workspace/repo`).
There, each folder in `Sources/` is a component (module) and each folder in `Tests/` is one leaf's
acceptance tests. `Package.swift` is generated from the folders and never
committed. Every leaf works on its own branch in its own working copy (`workspace/worktrees/<node>`) and
may touch several components (a vertical slice, doc 08 §1).

Each reconciler round:

1. checks the ledger's hash chain (a broken chain is a safe stop),
2. reads human signals (labels) from the tracker and state changes from the other team's system,
3. advances every node one step: break down → acceptance tests on the leaf's branch → build → pre-check
   of its own tests,
4. runs the landing queue one leaf at a time: rebase onto `main` (conflict → rework), run *all* tests
   (another node's test fails → requirements conflict, escalated), merge,
5. projects statuses and comments back to the tracker.

Every decision is an event in the ledger (`ledger.jsonl`); the working state is rebuilt from it after a
restart.

## Where the concepts live

| Concept (doc) | Code (in `Sources/AgentOSCore/` unless noted) |
|---|---|
| Work Node, phases, gates, flags, typed links (02, 00 §typed links) | `Model/Model.swift`, `Ledger/WorkingState.swift` |
| Ledger: append-only, hash chain, compare-and-swap, idempotent (04 §7) | `Ledger/Ledger.swift`, `Ledger/LedgerEvent.swift` |
| Tracker adapter: signals in; comments and statuses out (03, 05) | `Tracker/` |
| Deliberate signals, preview ("what you saw is what you get"), readiness (05) | `Reconciler/Reconciler.swift` (intake), `Reconciler/Policy.swift` |
| Reconciler round, one step per node, safe stop, restart recovery (07) | `Reconciler/Reconciler.swift` |
| Builder ≠ checker; locked acceptance tests; evidence pinned to a commit (02, 04, 08 §2) | `Reconciler.preCheck`, `Reconciler.land`, `Ledger.validate` |
| Vertical-slice leaves with a touch set; one test target per leaf (08 §1–2) | `NodeSpec.touches`, `NodeSpec.testTarget`, `Planner.childSpecs` |
| Leaf check: a node small enough is built as it is (02 §4, 05 §9) | `Reconciler.breakDown`, `EventKind.becameLeaf` |
| Branch per leaf, parallel build, optimistic landing queue (08 §4) | `Workspace/Workspace.swift`, `Reconciler.land`, `WorkingState.landingQueue` |
| Rework on merge conflict; requirements conflict → human (08 §5) | `Reconciler.land`, `Policy.maxReworks` |
| Escalation: attempt limit and the no-progress rule (02 §7) | `Policy.escalationReason` |
| External dependency in another system (03) | `External/MockExternalSystem.swift` |
| Observability: tree, attention list, ledger log (06) | `../App/` |

## Deliberate simplifications

- One process, with steps run one after another. There is no leader election or fencing. Leaves are still
  "parallel" where it matters for conflicts: each starts from the `main` of its time on its own branch.
- One repo and one profile, so the tree is at most two levels (an epic and its leaves) and there are no
  integration nodes. The leaf check is reduced to "would the breakdown give more than one child?"; if
  not, the ticket itself becomes the leaf (`EventKind.becameLeaf`). Going up the V is: the epic is proven
  when all leaves landed.
- No touch-set scheduling (doc 08 §4 layer 1), no batching in the landing queue, no leases.
- The scripted agents "implement" by writing each criterion as a *fact* in every component they touch
  (`"temperature unit": "Celsius"`). That's trivial, but it causes real merge conflicts and real
  regressions, and the checks are real `swift test` runs.
- No spec changes: a requirements conflict stays escalated. In production a human edits one of the
  tickets, which re-plans the affected nodes.
- One policy profile. No security or safety profiles, and no human review gate before merge.
- The ledger is a local JSONL file. Production would use a database and external anchoring (doc 04 §7).
