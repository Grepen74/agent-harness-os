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

| Setting | Built-in harness default | Repo may |
|---|---|---|
| Landing target | Local branch `agentos/main` | Choose another *local* branch name |
| Push / open pull requests | Never (phase 9: an opt-in setting; only the harness pushes, never agents) | Switch it off |
| Agent tools | Copilot CLI, with `git push`/`fetch`/`pull`/`remote`/`config`/`stash`, `gh` and network installs denied | Deny more |
| Agent models | Offered models, plus a default model per role (breakdown, acceptance tests, implementation); none = the CLI's default | Pick a model per role among the offered ones |
| Review | `agent`; default reviewer (the first offered reviewer model that differs from the implementer's, else the agent CLI's default model), or a specific model/command | Tighten to `agent+human`, overall or per area; choose an offered reviewer model |
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
  "review": { "level": "agent", "areas": { "App/Features/Weather": "agent+human" },
              "instructions": ".agentos/review.md", "maxRounds": 2 },
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

### Repo config reference

These are the supported `.agentos/config.json` paths, including container objects. Defaults below
distinguish **built-in** defaults from the **current harness settings** in Settings: changing Settings
changes the limits a repo may choose. Omitted agent models inherit per role; when no concrete model
is configured, Copilot CLI chooses its own default. Display titles are not config tokens:
**assume and report** must be written as `assume-and-report`.

| Config path | Accepted type / values | Omission default / required status | Harness restriction |
|---|---|---|---|
| `build` | Object containing optional prepare and build commands | No build steps | None beyond command safety below |
| `build.prepare` | String: shell command to prepare or generate the project | No prepare command | Runs before build, test and checks; failure stops the check run |
| `build.command` | String: shell command to build the repo | No separate build command | Runs after prepare, before test; failure stops the check run |
| `test` | Object containing the test command and optional suite selector | Required | Must supply `test.command` |
| `test.command` | String: shell command to run the full test suite | Required, including for the baseline | Must succeed; cannot replace required harness safety checks |
| `test.only` | String: suffix appended to the test command, with `{suite}` replaced by the leaf suite name | All tests run for each leaf; missing selector produces a warning | Full tests still run at landing |
| `checks` | Array of check objects, each with a name and command | Empty list; no extra checks | Adds required landing checks; does not replace tests or harness safety checks |
| `checks[].name` | String: human-readable check name | Required for each check object | None; identifies the check in evidence |
| `checks[].command` | String: shell command for the check | Required for each check object | Runs after tests, in array order; failure stops the check run |
| `leafTests` | Object naming the existing acceptance-test target and folder | Missing is a blocker for agents; not required for baseline alone | Agents need an existing test target; the harness does not restructure the repo |
| `leafTests.target` | String: existing acceptance-test target name | Required when `leafTests` is present | Must identify the target leaves add their tests to |
| `leafTests.folder` | String: repository-relative path to the acceptance-test folder | Required when `leafTests` is present | Each leaf writes only its own suite subfolder; approved tests are protected |
| `components` | Array of strings naming source components or repository paths for touch sets | Empty component list | None; declares existing components available to breakdown |
| `landing` | Object containing a local landing branch | Inherit the harness landing branch | Must keep proven work separate from the default branch |
| `landing.branch` | String: valid local branch name | Inherit harness setting; built-in `agentos/main` | Cannot be the default branch, a remote/ref name, `agentos`, or an `agentos/leaf/` branch |
| `signals` | Object containing disabled signal tokens | Inherit the harness's offered signals | May only disable signals, not enable ones the harness switched off |
| `signals.disable` | Array of signal-token strings, such as `go` or `harness:go`; multiple tokens allowed | Empty list; inherit harness signals | Only removes signals from the harness's offered set; unknown tokens produce a warning |
| `limits` | Object containing optional integer limits | Inherit current harness limits | Repo limits may only tighten the harness settings |
| `limits.maxAttempts` | Integer: maximum attempts per leaf | Inherit harness setting; built-in 3 | At least 1 and at most the current harness setting |
| `limits.maxReworks` | Integer: maximum reworks per leaf | Inherit harness setting; built-in 3 | At least 1 and at most the current harness setting |
| `limits.maxParallelAgents` | Integer: maximum concurrent harness-started agents | Inherit harness setting; built-in 2 | At least 1 and at most the current harness setting; does not count agents' sub-agents |
| `agents` | Object containing agent policy and context options | Inherit harness agent policy and default context | May only tighten policy; provider remains Copilot CLI |
| `agents.deny` | Array of strings naming additional denied tools or commands | No additions to the harness deny list | Additive union with harness denials; cannot remove them |
| `agents.models` | Object with optional role-specific model identifiers | Inherit each role's harness model, otherwise the CLI default | Only the role's configured model and offered alternatives are eligible |
| `agents.models.decomposer` | String: exact model identifier for the breakdown role | Inherit harness breakdown model; otherwise CLI default | Choose the current role model or an alternative offered in Settings |
| `agents.models.testAuthor` | String: exact model identifier for the acceptance-test role | Inherit harness test-author model; otherwise CLI default | Choose the current role model or an alternative offered in Settings |
| `agents.models.implementer` | String: exact model identifier for the implementation role | Inherit harness implementer model; otherwise CLI default | Choose the current role model or an alternative offered in Settings |
| `agents.guesswork` | String: `ask`, `assume-and-report`, or `autonomous` | Inherit harness setting; built-in `assume-and-report` | Same or stricter than current harness setting; strictest to loosest: `ask`, `assume-and-report`, `autonomous` |
| `agents.context` | Array of repository-relative tracked file paths or globs; only tracked matches are read | `["README.md", "AGENTS.md"]` | None beyond tracked-file selection; explicit list replaces default context, and an empty list selects none |
| `protectedPaths` | Array of strings: additional protected file paths, folder prefixes or globs | No additions to harness protected paths | Additive union; cannot remove harness protection or approved leaf-test protection |
| `tracker` | Object selecting the tracker and optional GitHub project | Local tracker | Supported tracker types only; GitHub requires usable `gh` authentication |
| `tracker.type` | String: `local` or `github-issues` | Required when `tracker` is present; absent tracker uses `local` | Unknown types block starting |
| `tracker.repo` | String: GitHub repository in `owner/name` form | Infer from the repo's `origin` remote for GitHub Issues | GitHub Issues needs a resolvable repository; not used by the local tracker |
| `tracker.project` | Object naming a GitHub Projects board and status mapping | No board; status is an `agentos:` issue label | GitHub Issues only; unreadable board or missing options warns and falls back to labels |
| `tracker.project.owner` | String: user or organization owner of the board | Required when `tracker.project` is present | Must identify an accessible board owner |
| `tracker.project.number` | Integer: GitHub project number | Required when `tracker.project` is present | Must identify an accessible project for that owner |
| `tracker.project.statusField` | String: name of the board's single-select status field | `Status` | Field and mapped options must exist for board status updates |
| `tracker.project.statusMap` | Object/map from harness status strings to board option-name strings; `""` (empty string) skips updates for that status and leaves the board unchanged | Unspecified statuses use defaults: Backlog, Ready, In progress, In review, Done | Nonempty mapped options must exist; not an exhaustive fixed list of option names |
| `review` | Object containing review level, area rules, instructions, round limit and model | Inherit harness review policy; default round limit 2 | May tighten review levels and choose an offered reviewer model |
| `review.level` | String: `none`, `agent`, or `agent+human` | Inherit current harness level; built-in `agent` | Same or stricter than harness level; strictest is `agent+human` |
| `review.areas` | Object/map from area names, path prefixes or globs to review-level strings: `none`, `agent`, `agent+human` | No additional area rules | Each level must be at least as strict as the effective overall level; strictest matching declared or changed area applies |
| `review.instructions` | String: repository-relative path to a review instructions file | No additional instructions file | Adds repository review context; does not replace the built-in checklist |
| `review.maxRounds` | Integer: reviews with findings allowed at each review stage before escalation | 2 | Must be positive; `harness:retry` resets the limit |
| `review.model` | String: exact reviewer model identifier | Inherit the harness reviewer selection; default reviewer uses the first offered reviewer model that differs from the implementer's, else the agent CLI's default model | Must be in the review-specific offered models in Settings, not merely the agent model list |

Commands are run with `/bin/sh -c` from the repo's top folder, not from the config's folder.
The order is prepare, build, test, then additional checks; the first failure stops the run.
Command strings are repo-specific shell commands, not a finite list of supported command names.
Agent tool denials and protected paths still apply; config commands do not remove harness safety checks.

Context paths and globs select tracked files on the scanned default branch. An unmatched context entry
produces a warning; correct the path/glob, track the document, or remove that entry. These selectors
do not read untracked files. Protected paths and denied tools, unlike context, only extend the harness's
lists. The harness always denies agent push/fetch/pull/remote/config/stash operations, `gh` and network
installs, and protects its steering files and approved acceptance tests.

### Choosing and activating repo overrides

In the Policy pane, use **Override in repo config…** for an overridable setting. Copy the JSON fragment,
using the exact config token rather than its display title (for example, assume and report is
`assume-and-report`). Choices follow the current harness settings: limits cannot increase, guesswork
cannot loosen, and model alternatives must be offered. CLI default inheritance is not a literal model
identifier to paste; if no concrete model is offered, leave that role unset.

Merge fragments into the existing `.agentos/config.json` object, preserving sibling keys and nested
fields; do not replace the whole file or paste a second top-level JSON object. For example, merge
`agents.guesswork` alongside existing `agents.context`, `agents.deny` and `agents.models`.
These fragments are partial config objects, not standalone runnable configs:

```json
{ "agents": { "guesswork": "ask" } }
```

```json
{ "limits": { "maxAttempts": 1, "maxReworks": 1, "maxParallelAgents": 1 } }
```

For a model override, copy the exact offered identifier from the action. The identifier below is a
placeholder to replace with that choice, not a model the harness necessarily offers:

```json
{ "agents": { "models": { "implementer": "model-offered-in-settings" } } }
```

The signals action supports multiple selections in `signals.disable`, not just one signal. Existing
disabled tokens are preserved by the fragment. When merging by hand, arrays replace arrays: retain
existing disables as well as newly selected ones. For example, disable both fast-track go and preview:

```json
{ "signals": { "disable": ["go", "preview"] } }
```

When no config is loaded, the draft includes the commands guessed by the scan and chosen overrides.
Selecting or copying an override does not write a file. Review the draft, then explicitly choose
**Create .agentos/config.json** to write it into your checkout and open it. An existing checkout file
is opened, not overwritten. The harness never commits the file for you.

If commands cannot be guessed, an override-only draft can be incomplete: `test.command` is required.
Such an incomplete draft is not a valid runnable config and cannot load until you supply the missing
test command; agents also need `leafTests`. Creating a draft does not bypass these requirements.

Commit the completed config on the repo's **default branch** (`main` in these examples), then choose
**Rescan**. Rescan reloads the committed config and applies the policy without a restart; an agent round
already under way finishes before agents use the new config. Editing or creating the checkout file alone
does not activate it. Run the baseline for the default branch's new commit before starting agents.

### Review before implementation and landing

Harness settings save review as `{"level":"agent","reviewer":{"type":"default"},"offeredModels":[]}`.
Older saved settings retain the agent minimum. A specific reviewer uses
`{"type":"specific","model":"model-name"}` or `{"type":"specific","command":"local-review --stdin"}`.
Commands receive the complete review prompt on stdin and must return
`{"passed":true,"findings":[]}`, optionally with `"testFindings":[…]` at the change stage and `"followUps":[…]` (nonzero exit or invalid JSON stops work for a person).
A repo can set `review.model` only to a model in the review-specific offered list.
When the CLI says a model isn't available to your account, a Copilot reviewer tries the other offered
reviewer models that differ from the implementer's, then the agent CLI's default; the review event in
the ledger names the models skipped and the one that reviewed. An agent role whose configured model
isn't available runs with the CLI's default. The run's log starts with a note of the switch.
The strictest level among the overall policy and every declared or actually changed area applies.
A lower repo level, including an area below the overall level, is a start blocker. The effective
Review level and Reviewer rows each retain their own harness/repo source.

The reviewer checks authored acceptance tests against the ticket before implementation starts. Weak
tests return to their author with findings. After all landing checks pass, the reviewer receives the
ticket, complete diff against the landing branch, recent same-file history, and configured repository
rules. The built-in checklist covers regressions and loosened constraints, per-line/loop I/O and
allocation, duplicated logic, and tests that fail to prove the requirement. Rejected changes return to
the implementer without unlocking the acceptance tests. Since the implementer may not change them, the
reviewer lists problems in the ticket's own acceptance tests separately (`testFindings`): those send the
ticket back to the test author, keeping only its tests commit, and the implementer then builds again with
the remaining findings. If the implementer changes nothing for a review's findings (it may think they are
wrong, or about the tests), the harness doesn't submit the same branch for another review: it stops with
"Needs input". `harness:retest` then sends the ticket to the test author; a comment plus `harness:retry`
sends the answer to the implementer. After `maxRounds` reviews with findings at
either stage (default 2), work escalates; a human `harness:retry` resets the limit, and so does
`harness:retest`, since reviews of the discarded tests and code no longer count.

So that reviews converge, a later review round gets the findings of the earlier rounds at that stage.
The reviewer first checks each earlier finding is fixed. A new finding must be a defect that makes an
acceptance criterion fail or a regression the change introduced, and starts with "New:". Improvements,
out-of-scope and pre-existing problems go in `followUps`. The harness posts follow-ups on the ticket for a
person to file as new tickets; they never fail the review. When the round limit is reached, the
escalation suggests splitting the ticket into smaller tickets.

UI changes must include snapshot evidence and confirmation that windows actually open and close.
The implementer supplies `.agentos-ui-evidence.json` with `snapshotPaths`, `windowsOpened`,
`windowsClosed`, `beforeScreenshot` and `afterScreenshot`; file paths must refer to evidence inside
the worktree, outside the per-run scratch folder. The workspace copies those files to artifact storage
so removing a landed worktree does not lose them.

At `agent+human`, a passing candidate stays **In review** until a fresh human `harness:build`
approves that reviewed commit. Earlier build gates and agent signals cannot approve it.
UI candidates additionally need both screenshots. A changed candidate is reviewed and approved anew.
Every review is a ledger event, replayed onto the node and displayed with its findings and UI evidence.
Scripted/legacy teams without a reviewer retain their existing checks-only behavior.

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
| No source file over 1,000 lines: parallel leaves often change the same large file and conflict at landing | Warning |
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
  snapshots/       a detached checkout of agentos/main for each preview or breakdown, removed when it ends
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
  When only other proven tickets' tests fail, the harness checks latest `agentos/main` without the change
  and reruns the candidate. A failing baseline is a main/infrastructure problem, with no failed attempt;
  fix it and add `harness:retry`. If both reruns pass, the harness reports unreliable tests and lands.
  Only a passing baseline and repeated candidate failure can become a requirements conflict. Reports
  name the failing tests and include both rerun outcomes.
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
- **Parallel work.** Up to *max parallel agents* nodes take their step at the same time (breakdown,
  tests, build, pre-check), each in its own worktree. A round starts steps and returns without waiting
  for them: an agent keeps running across rounds, a later round fills a freed slot, and each finished
  step is reported once, by the next round that returns. Agents started by earlier rounds count against
  the limit. While a node or one of its descendants has a step under way, `harness:retry`, `retest` and
  `replan` on it are rejected with a reply, so its worktree is never discarded under a running agent.
  The limit counts the agents the harness starts, not the sub-agents they use.

  Two kinds of work still hold their own round open. A preview waits for the decomposer before its round
  returns; an approved breakdown is decomposed by a scheduled step, across rounds like other agents.
  Landing is synchronous and one at a time: the round that lands waits for the rebase, the landing checks
  and the merge, and a round requested meanwhile doesn't start a second landing; agents from earlier
  rounds keep running meanwhile. A landing takes a slot, and while a change waits to land, scheduling
  keeps a slot free for it so new work can't starve the queue.
 Adding and removing worktrees is
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
  - **Stop**: cancels this exact run and waits for its task and child processes to end. The ledger and
    ticket name the person who stopped it; no failed attempt is counted. Add `harness:retry` to resume.
  - **Log**: the agent's output, followed live. Copilot writes each step as it goes (only the decomposer
    runs with `-s`, since its answer is parsed). The file is kept, and the node's details list every agent
    run with its log. Checks have no live log; theirs is recorded as evidence when they finish.
  - **Changes**: what the worktree changed since it left the landing branch, committed or not, including new
    files. Read with `git --no-optional-locks`, so looking never takes the index lock from an agent.
  - **Finder** and **Xcode**: the worktree itself. Look, don't change: anything changed there is committed
    as the agent's work.
- **Run cleanup.** Pause prevents new rounds but lets the current work finish. Closing a repository
  window or quitting the app stops and awaits all its active agents and checks, recording why they
  ended. Opening a repository durably abandons old runs before readiness blockers are considered.
  A git command killed mid-write (a timeout, quitting) can leave a lock such as `index.lock` behind.
  When the harness's own git hits a lock file that no process has open, it removes it and runs the
  command once more; a lock some process still holds is left alone.
  Post-start errors always finish their run with the diagnostic. Checks that write nothing for
  10 minutes are ended as hung and retain their log; `CommandCheckRunner.idleTimeout` configures this
  limit independently of the 30-minute total timeout. Any output, including partial lines, resets it.

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
     questions records nothing; you answer in a comment (or edit the ticket) and preview again. The next
     preview reads those answers, and adopting the ticket (breakdown or go) keeps them for later agents.
   - The decomposer runs in a read-only snapshot of `agentos/main` (a detached worktree, removed afterwards),
     so it reads the code and the repo's `AGENTS.md` when it splits the work. Anything it writes there is
     thrown away. If the snapshot can't be made, it splits from the ticket alone.
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
     are refused. The ticket's status is *Replanned* and its children's *Paused* until then. The work tree
     shows the same statuses as the tickets; the ledger's phase is in the node's details.
   - **Dependencies between tickets.** `Blocked by: #12` on a ticket waits until `GH-12` is proven here. On
     a ticket that's broken down, it holds every leaf unless the breakdown gave that dependency to particular
     leaves.
   - **Projects board (opt-in).** With `tracker.project` (owner, number, optional `statusField` and
     `statusMap`), the board's Status field follows the harness: Specifying, Breaking down, Replanned (waits for
     preview, breakdown or go) and Paused (a replanned ticket's children) → Backlog,
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
   merged). Leaves in progress then rebase as usual; conflicts go to rework, as at landing. Leaves whose
   agent is running or about to start are left alone and catch up on a later round. Catch-up runs at the
   start of every round, so work started or retried in that round begins from the latest `main`; an
   unresolved catch-up conflict stays the status of its tickets after the round. Nothing is fetched:
   `main` is whatever your clone has.
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
