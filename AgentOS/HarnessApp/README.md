# AgentOS Harness app

A Mac app for the agent harness. It has two kinds of window:
- the **simulator** (below), and
- **repository windows** for real repos (File → Open Repository…). These run the read-only readiness
  scan, show the effective policy, run the baseline and, once nothing blocks it, let Copilot agents work
  on tickets from a local tracker, landing proven work on local requirement branches `agentos/<ticket key>`
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
                                            ├─▶ Landing queue: rebase → all tests → requirement branch
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

A round doesn't wait for the agents it starts. An agent keeps working across rounds in the background, and
later rounds meanwhile pick up your labels, land finished work and start other agents, up to *max parallel
agents*. A round reports an agent's result once, in the first round after it finished. **Pause** stops
starting rounds but lets running agents finish; closing the window or quitting stops them and waits for
their cleanup, and a rescan waits for them before it replaces the session.

Two things still hold their own round open: a `harness:preview` waits for the decomposer before the round
returns (an approved breakdown runs like any other agent, across rounds), and landing runs synchronously in
the round that lands, one batch (or single change) at a time, while agents started by earlier rounds keep running. A landing
takes one of the *max parallel agents* slots, and while a change waits to land, rounds keep a slot free for it.

**Landing batch size** defaults to 4; set it to 1 for the existing one-at-a-time landing, review and
failure diagnosis. A repo can lower the setting with `limits.landingBatchSize`, but cannot raise it.
Waiting changes on the same requirement branch are taken oldest first, up to that size, and checked
together once in a separate working copy based on the latest requirement tip. Different requirements
never share a batch. Agent-reviewed changes are rebased onto the requirement branch and reviewed
individually before joining; failed reviews return findings and stay out. Only agent-and-human review
requires individual landing and `harness:build` approval of the exact candidate commit.
Conflicting nodes are removed for merge-conflict rework without a failed attempt, adding newly
discovered conflicting files to their predicted paths. After each node is applied, the single-landing
protected-tests check runs; tampered nodes are removed as failed landing checks with the tampering
summary. The remaining nodes are still checked together and can land in the same round.
On a pass, a compare-and-swap moves the branch to the checked tip, preserving each node's separate
commits in queue order without UI evidence in their history. Each node becomes Proven with its own
landed commit, shared batch-check evidence, and a landed comment naming the batch. The ledger records
the batch name, branch, ordered nodes, candidate and result. Its `landingBatchMemberRemoved` rows name
each removed node and its own conflict or tampering reason, also shown in the ledger pane.
A checked-out requirement waits without starting a run; that wait is checked again before the batch
moves the branch.
Runner crashes get one unchanged retry; a second crash escalates every member without a failed attempt.
A failed batch first gets a quiet full rerun, waiting for existing agents and previews and blocking new
ones throughout diagnosis. A passing rerun lands normally with an "Unreliable test" comment on each
ticket. Otherwise the failing suites run alone on the batch tip and the latest requirement branch
without it. A runner problem, an empty selection, tests failing without the batch, or unknown failing
suites escalates every member with "Landing infrastructure problem" evidence and no failed attempt,
without splitting. Fix the branch or runner, then add `harness:retry`. The ledger pane shows the reruns,
results and outcome; see [real-repo mode](docs/real-repo-mode.md) for the full diagnosis flow.

## Open a real repo

A breakdown child can include `affectedTests`, listing existing test names (such as
`FlowTests.someTest`) or repository-relative test files whose behaviour it deliberately changes.
Its criteria must still say what those tests should expect now. The field is optional and is retained
in previews and the ledger; an omitted, null or empty list means no affected tests. Adding or changing
affected tests changes the child's spec fingerprint, so replanning does not keep its old tests and approvals.

Before approving a breakdown with `harness:go`, use `harness:preview`: each child's line ends with
`affected tests:` and its entries when present. The **Broken down** and **No breakdown needed** comments
show them too. In the **Work** pane, select a node to see **Affected tests**, one entry per line,
or **–** when there are none.

Approving a matching preview with `harness:breakdown` or `harness:go` records a **test updates approved**
ledger event for each affected child, authored by the person who opened the breakdown gate. Test names
are resolved to repository-relative files; a leaf check records the approval on the original ticket.
The Ledger pane names every approved file. Without a matching preview, affected tests are **not approved**.
The breakdown comment also marks unresolved tests, or tests owned by another ticket that has not landed,
as **not approved**, naming the owner whose work is still in progress. Land that work first, then use
`harness:replan` and `harness:preview` before approving again.

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
**Open .agentos/config.json** opens the copy in your checkout in your default editor. If the repo has none,
the pane shows a draft guessed from the scan, and **Create .agentos/config.json** writes that draft into your
checkout. Check it, commit it on `main` yourself, then **Rescan** (toolbar, ⌘R). A rescan reloads the config
and policy: no restart needed, and agents continue with the new config after the round under way. The harness reads the config only from
`main`. It writes into your checkout only when you ask it to, never commits, and agents never edit the files
that steer the harness (the config, AGENTS.md, CONTRIBUTING, CODEOWNERS): otherwise they could raise their own limits.

**Avoid building overlapping work at the same time** is on by default in **Settings**, including when
loading settings saved before it existed. A repo may turn it on with `limits.avoidOverlappingWork: true`,
but cannot turn it off when the harness has it on. The Policy pane shows **On** or **Off** and its source:
explicit `true` is *repo*, otherwise *harness*. A refused `false` keeps it **On**, shows
`repo asked for false: refused`, and adds a `config.policy` readiness blocker; remove the override or set it to `true`.

**Push / open pull requests** is off by default in **Settings** and saved with the other harness settings.
Repo config `pullRequests: false` disables publishing for that repo. An absent key inherits Settings;
`true` cannot override an off harness setting and produces a `config.policy` blocker.
Once every leaf of a requirement is proven, the harness runs the full test command and configured checks
again on its requirement branch tip, storing the result and full log in the ledger's evidence.
A failure waits for a person without agent rework or automatic retries: fix the problem, then use
`harness:retry`. With publishing off, a passing requirement stays local and **In review** until a person
merges its branch into `main`; the harness detects the merge and shows **Done**.

With publishing on, the harness pushes only the requirement's `agentos/<ticket key>` branch to `origin`
and opens one pull request into `main`, updating it after later catch-ups and landings. It never force-pushes,
pushes tags or leaf branches, or merges pull requests. The description includes the breakdown, criterion/test
mapping, checks and local artifact names with SHA-256 hashes; no evidence is uploaded. Publication errors
appear on the ticket and under **Needs attention**; only a human `harness:retry` resumes publication.

Each publishing round first fetches origin's default branch. The baseline, requirement catch-up,
cross-requirement dependencies, merge detection and new branches use `origin/<default branch>`, without
changing your local branches, checkout, index or files. Origin-only merges are detected without pulling.
A fetch failure shows the git error in **Needs attention** and uses the last fetched commit; fetching
retries next round and a successful fetch clears the warning. With publishing off, nothing is fetched
and the local default branch is used.

The requirement follows its pull request: open is **In review**, merged is **Done**, and closed without
merging is **Needs input**, on ticket labels and comments and the configured board's mapped status.
After a close, `harness:retry` pushes again and reopens the same pull request. After a merge, build signals
are refused with a link to the merged pull request and a request to open a follow-up ticket.

Use **Override in repo config…** in the Policy pane to choose a permitted value and copy its full-path
JSON fragment. Use exact config tokens: **assume and report** is `assume-and-report`. Merge the fragment
into the existing config, preserving sibling fields; model choices come from harness Settings, and
`signals.disable` supports multiple signals. See the [complete config reference and override workflow](docs/real-repo-mode.md#repo-config-reference).

When there is no config, the draft includes selected overrides alongside guessed commands. Selecting
or copying does not write anything: only explicit **Create .agentos/config.json** writes the draft into
your checkout (an existing file is opened, not overwritten). An incomplete draft still needs the required
`test.command` before it can load; agents also need `leafTests`. Finish it, commit on the default branch,
then **Rescan** to activate the config without restarting.

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
folder. Proven work lands on `agentos/<ticket key>`; review, merge and push it yourself. **Settings** picks the
models offered to agents and a default per role; a repo may choose among them in `agents.models`. From the
terminal: `swift run agentos work <path> --ticket "<title>" --criterion "<criterion>" --go`.

Breakdown previews list each leaf's predicted files or directory prefixes after its touch set when
provided. The work pane shows them in **Paths**, or **–** when there are no predictions. Replanning
refreshes predictions even for leaves whose tickets, tests and approvals are kept.

Each time a parent becomes proven, its ticket gets one cost comment after **✅ Proven**, without
reposting in later rounds or after restarting. It lists linked leaves at every depth in current breakdown
order, followed by **Breakdown** (recorded credits on the parent and nested parents) and **Total**.
Amounts use up to two decimals without trailing zeros, such as `1.5 AI credits`. All recorded runs count,
including failed attempts, retries and earlier runs of retained nodes; removed nodes are excluded.
A parent proven again after a replan gets a new summary without changing its historical comments.

With overlap avoidance on, a ready leaf waits for overlapping work that is building, being checked,
in review or landing. The harness compares predicted paths with the active work's changed files when
known, or its predictions otherwise; missing paths fall back to shared touch-set components. The leaf
stays **Ready**. Its ticket and work-pane detail explain which node and paths or components it waits
for, that it starts by itself once the other work lands or stops being in progress, and that nothing
needs to be done. An unchanged explanation is not posted again, even after a restart. Holds and their
ends are recorded in the ledger; the pane clears the explanation once the hold ends.

Repository teams review acceptance tests before implementation and review the complete change after all
landing checks pass. **Settings → Review** sets the minimum (`none`, `agent`, or `agent+human`), reviewer
and models a repo may choose. The default is agent review with an explicit model different from the
configured implementer. The repo's `review` config may tighten levels overall or by touched area, name
an instructions file, set `maxRounds` (default 2), and choose an offered reviewer model. Looser levels
and unoffered models block starting. The Policy pane shows the effective level and reviewer with sources.

Findings return to the test author or implementer; repeated findings escalate with `harness:retry` as the
next step. Reviews and findings appear on the node and in the ledger. At `agent+human`, a passing candidate
waits **In review** for a fresh human `harness:build`, even if building was already approved.

The test author's prompt lists tests a person approved for the node. It may update them where the ticket's
change requires it, even without a criterion naming them; unapproved tests still need a criterion deliberately
changing what they check. It lists changed files in `updatedTests`; only files inside the updatable test areas
and outside protected paths are kept and fingerprinted. The implementer still may not change them, approved
or not. Test review treats approved updates as in scope; change review lists approved tests the branch changed
and reports weakened or removed checks as findings.

When a ticket waits because **another test conflicts with this ticket**, add `harness:update-test` to
approve updating the reported test on this ticket's branch. An optional guidance comment made after the
harness asked is recorded as the answer to **How to proceed with the conflicting test** and reaches the
restarted test author. The ledger records the exact approved file and the approving person; the signal
clears the input wait and any escalation, resets escalated attempts and broken-test return counts, and
returns the ticket to test authoring. Only tests inside the updatable test areas and outside protected
paths qualify, and another node's test must wait until its owner lands. The test author lists its change
in `updatedTests`; it is kept and fingerprinted on this branch, never editable by the implementer.
Alternatively, change the test on the default branch and commit, then add `harness:retry` once the
harness catches up.

UI changes require snapshots and evidence that windows open and close; human UI review also requires
before and after screenshots. Implementers report actual evidence in `.agentos-ui-evidence.json` at the
worktree root; evidence files are retained in the repository's artifact storage.

**Pause** stops new rounds, not work already running. Each agent or check in **Running now** has a
**Stop** button: it waits for the run and its child processes to end, records who stopped it, and leaves
the node waiting for `harness:retry` without adding a failed attempt. A running preview is listed there
too; stopping it says so on its ticket, and `harness:preview` starts it again. Closing the repository window or
quitting also waits for running work to stop. Opening a repo abandons leftover runs from a previous
app session even if readiness blockers prevent agents from starting. Checks that produce no output
for 10 minutes are reported as hung, with their log retained.

## Browsing the ledger

In repository and simulator windows, the ledger starts with the newest **200** records, newest first.
**Show older** adds 200 matching records at a time and disappears when all matches are displayed.
The header always counts the entire ledger, regardless of the displayed page or filters.

Use **Ticket** to select **All tickets** (including events without a ticket) or one exact ledger node.
Choices include nodes no longer in tracker results; known nodes show their canonical ticket names and
unknown nodes show their NodeIDs. Selecting a parent does not include its descendants.
**Event kind** selects **All event kinds** or a case independent of its payload. Both filters apply
together across the complete ledger before paging, so older matches remain available.
Changing either filter returns to 200 records; live refresh preserves filters and the expanded limit.
Reset, restart and restore discard stale pages. Agent-run history remains complete regardless of these controls.

### File-backed ledger benchmark

The explicitly opt-in Swift Testing benchmark lives in
`AgentOSKit/Tests/AgentOSAdaptersTests/GH_70Tests/`. From the repository root, run:

```sh
cd AgentOS/HarnessApp && xcodegen generate
cd AgentOSKit && AGENTOS_RUN_GH70_BENCHMARK=1 swift test -c release --filter GH_70Tests
```

Without `AGENTOS_RUN_GH70_BENCHMARK=1`, ordinary correctness tests skip the benchmark and do not
enforce hardware-dependent timing thresholds. Opting in with a debug build fails with a reminder
to use `-c release`.

Fixtures are temporary `FileLedgerStore` JSONL files containing 20,000 deterministic, valid,
hash-chained records evenly distributed across 100 nodes (200 per node). Fixture creation, opening,
full verification and checkpoint preparation are outside the measured intervals. Temporary fixtures
are removed on success or failure.

Each median uses 20 measurements after one warm-up and is the arithmetic mean of the 10th and 11th
sorted samples. Timings are `ContinuousClock` wall time in milliseconds, including actor hops:

| Reported metric | Measured operation |
|---|---|
| `unchanged_quick_check_median` | `verifyIncrementally()` on a checkpointed 20,000-record file with no writes. |
| `after_one_append_quick_check_median` | `verifyIncrementally()` after exactly one legitimate append, using an independently copied, opened and checkpointed fixture for each sample and warm-up. The append itself is not timed. |
| `indexed_original_200_records_median` | `records(for:)` returning node `gh70-node-42`'s original 200 records; appends target node 0 instead. |
| `full_verify_chain_reference` | One full `verifyChain()` measurement on the original 20,000-record fixture, reported for comparison rather than as a median or threshold. |

Both quick checks include verified-prefix digest checking of the real file; they do not bypass
historical tamper detection or substitute an in-memory store. Warm-up and measured results are
consumed and validated outside the timing intervals: integrity reports must succeed, and lookups must
return the expected count, node, event IDs, positions and hashes. Correctness tests also check historical
tampering with restored modification times, with and without an intervening legitimate append.

The release benchmark requires both quick-check medians to be below **20 ms** and the indexed-lookup
median below **1 ms**. Its output includes fixture record count and byte size, node count, machine model,
architecture, OS, Swift version, build configuration, sample count and units. Reporting and validation
are not timed; results depend on the machine and current load.

## Try this in the app

1. **⚙︎ → Load demo tickets.** Press **Step** or **Run**: nothing happens. Tickets need a deliberate signal (doc 05).
2. On **APP-2 Dark mode**, add `harness:preview`. It is rejected with an explanation because it has no
   acceptance criteria (the Definition of Ready). Every rejection ends with *What you can do now*: the
   signals that do apply to the ticket at this point. Edit the ticket and try again.
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
   checks latest main without the change and reruns the candidate. A passing baseline and repeated
   candidate failure escalate a **requirements conflict** instead of merging. Its other leaf lands normally.
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
- Changed your mind after a breakdown? Edit the ticket and add `harness:replan` (before `harness:build`).
  The ticket waits for preview, breakdown or go again. That breakdown keeps the child tickets it still
  contains unchanged (with their tests) and marks the others *Superseded*.
- `Blocked by` another ticket's key (e.g. `APP-1`) makes a ticket wait until that one is proven.
- Choose **⚙︎ → Restart harness** while it is running. State reloads from the ledger and unfinished runs
  are reclaimed.
- Switch **Agents** to *Copilot CLI* to have real agents decompose the work, write tests and implement.
  This is slow and uses your Copilot quota.
- Open the workspace in Finder to inspect the repo, the leaves' working copies and the check logs
  (`artifacts/`). `git log` in `workspace/repo` shows every landed commit, authored by the run that built it.
