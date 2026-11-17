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
6. Proven work lands on the local requirement branch **`agentos/<ticket key>`**, for example `agentos/GH-12`.
   You review, merge and push it yourself. Nothing is pushed automatically.

## What changes compared to the simulator

| | Simulator | Real repo |
|---|---|---|
| Repo | Created by the harness, `Package.swift` generated | Exists. The harness never restructures it, so it must **discover** how it's built |
| Build and test | `swift test`, hard-coded | Commands from the repo config, e.g. `xcodebuild test -scheme App -destination 'platform=iOS Simulator,name=iPhone 14,OS=18.6'` |
| A leaf's tests | A new test target per leaf | Files in an **existing** test target, in the leaf's own folder `<leafTests.folder>/<suite>`, as a suite named after the leaf (e.g. `WORK_1Tests`), run with `test.only` (e.g. `-only-testing:`; XCTest and Swift Testing). The protected-tests fingerprint covers that folder |
| Components (touch set) | `Sources/<Component>` folders | Detected: Swift package targets, Xcode targets, or top-level folders; listed in the repo config |
| Agents | Scripted or Copilot CLI | Copilot CLI only. It already reads AGENTS.md and `.github/copilot-instructions.md` |
| Working copies | Harness-owned folder | Git worktrees **outside** the repo folder; your own checkout is never touched |
| Landing | Fast-forward the requirement branch | Fast-forward the requirement branch |
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
| Landing target | Local requirement branch `agentos/<ticket key>` | No override; `landing.branch` is ignored with a warning |
| Push / open pull requests | Never (phase 9: an opt-in setting; only the harness pushes, never agents) | Switch it off |
| Agent tools | Copilot CLI, with `git push`/`fetch`/`pull`/`remote`/`config`/`stash`, `gh` and network installs denied | Deny more |
| Agent models | Offered models, plus a default model per role (breakdown, acceptance tests, implementation); none = the CLI's default | Pick a model per role among the offered ones |
| Reasoning effort | A default effort per role (`copilot --reasoning-effort`; none = the CLI's default) and the highest effort a repo may choose (built-in `high`) | Pick an effort per role up to that cap, or up to the role's harness effort if higher |
| Review | `agent`; default reviewer (the first offered reviewer model that differs from the implementer's, else the agent CLI's default model), or a specific model/command | Tighten to `agent+human`, overall or per area; choose an offered reviewer model |
| Agent timeouts | Per role: 20 minutes, 10 for the diagnoser; the longest a repo may choose: 1 hour (at most 4) | Choose per role, longer or shorter, up to the longest allowed |
| Max attempts / reworks per leaf | 3 / 3 | Lower |
| Max parallel agents | 2 | Lower |
| Avoid building overlapping work at the same time | On | Turn on, but not off |
| Guesswork | `assume and report`: carry on and post assumptions; a leaf whose work rests on assumptions waits for a person to see its acceptance tests before build, even under `harness:go`. Guesses about what users observe (what to check, which screen, which behaviour) always stop the node; guesses about implementation don't. Other levels: `ask` (assumptions are questions too), `autonomous` (assumptions are posted, nothing waits) | Choose a stricter level (`agents.guesswork`) |
| Signals people may use (doc 05 §3) | All, including `harness:go` | Switch some off, e.g. `go` to force a breakdown review |
| Required checks | Build + the leaf's tests on branch; all tests at landing | Add more (lint, snapshot tests…) |
| Protected paths | Tests of proven leaves, `.agentos/`, AGENTS.md, CONTRIBUTING, CODEOWNERS, copilot-instructions | Add more |

The policy pane shows every effective value with its source (*harness*, *repo*). A repo value that tries to
loosen a limit becomes a blocker finding, not a silent override, and the harness's value applies.
The retired `landing.branch` key has no effect, even when it names the default branch.
Disabling a signal the harness doesn't know is a warning.

**Avoid building overlapping work at the same time** is a Settings toggle, on by default even for older saved
settings. A repo may turn it on with `limits.avoidOverlappingWork: true`, but cannot turn it off when the
harness has it on. The effective policy carries this choice to the reconciler. The Policy pane shows
**On** or **Off** with source *repo* for explicit `true`, and *harness* otherwise. A refused `false`
keeps **On** with `repo asked for false: refused` and a `config.policy` readiness blocker.
Remove `limits.avoidOverlappingWork` or set it to `true` to clear that blocker.

With overlap avoidance on, a ready leaf is held while its predicted repository-relative paths overlap
work that is building, being checked, in review (including human review), or landing. The comparison uses
the in-progress node's actual changed files once its implementer has submitted work, and its predicted
paths otherwise. The whole branch diff is recorded in the ledger at submission and replaces predictions,
including when the diff is empty (which holds no other work). A reset for rework clears that recorded diff
until the next submission. Paths overlap when they name the same file or one is a directory prefix of the
other, on whole path components. If either node has no paths (except a known empty actual diff), the
harness compares their touch-set component names instead; without shared components there is no hold.
Unrelated ready leaves can still start.

When a landing rebase conflicts, conflicting files not already covered by the leaf's predictions are
appended to them, even if it had no predictions before. The ledger records the added files, so they
survive replay and appear in the work pane's **Paths** row. Rework uses these expanded predictions to
avoid overlapping work again. A conflict with no named files leaves predictions unchanged.

A held leaf stays **Ready**, with no human-attention flag. Its ticket gets one comment naming the node
it waits for and all overlapping paths, or shared components for the touch-set fallback.
The same explanation appears in the work pane: the leaf starts by itself once the other node lands or
stops being in progress (escalated, needs input, replanned, or its ticket closed); nothing needs to be done.
An unchanged hold is not commented again in later rounds or after restarting the harness. A different
blocking node or different overlaps gets a new explanation. Hold starts and ends, including the blocker
and paths or components, are recorded in the ledger. The pane's explanation disappears when the hold
ends, the leaf starts, or it is no longer eligible to build.

**Detect models** (Settings › Agents) asks the Copilot CLI which models your account offers and which reasoning
efforts each supports. It talks to `copilot --acp` (the Agent Client Protocol): one session in an empty temporary
folder, switched through each model to read its efforts, with no prompt, so no model runs. The CLI keeps that
empty session in its history. You tick which models to offer to agents and reviewers; nothing is saved until you
press Save, and offered models stay offered. A failed or timed-out detection says why and changes nothing; so does
cancelling it, or closing Settings while it runs, which stops the CLI. The CLI's own requests during detection (such
as asking permission) are declined. After
that:
- Settings flags offered models that weren't detected as possibly unavailable, without removing them.
- Each role's effort picker offers only the levels its model supports; the default-model choice names the CLI's
  default seen when detecting (a repository default in a trusted folder may differ).
- The policy pane shows when models were last detected, notes a role whose model wasn't detected, and notes an
  effort the role's model doesn't support (the run then falls back to the CLI's default effort).

Models change with the account and the CLI, so detection is a guide: runs still fall back when a model or effort
isn't available.

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
| `leafTests.updatable` | Array of repository-relative folders holding other existing tests (say, other test targets) | Only `leafTests.folder` | Where the test author may update other work's tests a criterion deliberately changes; nobody else may change tests there. The repo's top folder, absolute paths and `..` are ignored |
| `components` | Array of strings naming source components or repository paths for touch sets | Empty component list | None; declares existing components available to breakdown |
| `landing` | Retired landing configuration object | Requirement-scoped branches | Remove this obsolete object |
| `landing.branch` | String branch name; ignored, with no effect | Always `agentos/<ticket key>` | A warning says the key is ignored and its value has no effect; remove it |
| `signals` | Object containing disabled signal tokens | Inherit the harness's offered signals | May only disable signals, not enable ones the harness switched off |
| `signals.disable` | Array of signal-token strings, such as `go` or `harness:go`; multiple tokens allowed | Empty list; inherit harness signals | Only removes signals from the harness's offered set; unknown tokens produce a warning |
| `limits` | Object containing optional integer limits and overlap protection | Inherit current harness limits | Repo limits may only tighten the harness settings |
| `limits.maxAttempts` | Integer: maximum attempts per leaf | Inherit harness setting; built-in 3 | At least 1 and at most the current harness setting |
| `limits.maxReworks` | Integer: maximum reworks per leaf | Inherit harness setting; built-in 3 | At least 1 and at most the current harness setting |
| `limits.maxAgentRuns` | Integer: test-author and implementer runs per ticket since a person last acted on it | Inherit harness setting; built-in 12 | At least 1 and at most the current harness setting; any human action on the ticket starts a new budget |
| `limits.maxParallelAgents` | Integer: maximum concurrent harness-started agents | Inherit harness setting; built-in 2 | At least 1 and at most the current harness setting; does not count agents' sub-agents |
| `limits.avoidOverlappingWork` | Boolean: avoid building overlapping work at the same time | Inherit harness setting; built-in `true` | A repo may turn it on, not off; `false` is refused when the harness has it on |
| `agents` | Object containing agent policy and context options | Inherit harness agent policy and default context | May only tighten policy; provider remains Copilot CLI |
| `agents.deny` | Array of strings naming additional denied tools or commands | No additions to the harness deny list | Additive union with harness denials; cannot remove them |
| `agents.models` | Object with optional role-specific model identifiers | Inherit each role's harness model, otherwise the CLI default | Only the role's configured model and offered alternatives are eligible |
| `agents.models.decomposer` | String: exact model identifier for the breakdown role | Inherit harness breakdown model; otherwise CLI default | Choose the current role model or an alternative offered in Settings |
| `agents.models.testAuthor` | String: exact model identifier for the acceptance-test role | Inherit harness test-author model; otherwise CLI default | Choose the current role model or an alternative offered in Settings |
| `agents.models.implementer` | String: exact model identifier for the implementation role | Inherit harness implementer model; otherwise CLI default | Choose the current role model or an alternative offered in Settings |
| `agents.efforts` | Object with optional role-specific (`decomposer`, `testAuthor`, `implementer`) reasoning efforts: `none`, `minimal`, `low`, `medium`, `high`, `xhigh` or `max` | Inherit each role's harness effort, otherwise the CLI default | At most the harness's cap, or the role's harness effort if higher; unknown levels are refused. A model that doesn't support the level runs with the CLI's default effort, noted in the agent log. Higher effort takes longer: raise the role's timeout too |
| `agents.efforts.decomposer` | String: reasoning effort for the breakdown role | Inherit harness breakdown effort; otherwise CLI default | At most the harness's cap, or the role's harness effort if higher |
| `agents.efforts.testAuthor` | String: reasoning effort for the acceptance-test role | Inherit harness test-author effort; otherwise CLI default | At most the harness's cap, or the role's harness effort if higher |
| `agents.efforts.implementer` | String: reasoning effort for the implementation role | Inherit harness implementer effort; otherwise CLI default | At most the harness's cap, or the role's harness effort if higher |
| `agents.timeouts` | Object from agent role (`decomposer`, `testAuthor`, `implementer`, `reviewer`, `diagnoser`) to seconds | Each role's harness timeout; built-in 1200 for each role, 600 for the diagnoser | 60 seconds to the harness's longest timeout (built-in 3600); may raise as well as lower the harness's value; unknown roles and values out of range are refused, and that role keeps the harness's timeout |
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
| `review.maxRounds` | Integer: reviews with findings allowed at each review stage before escalation | 2 | Must be positive; `harness:retry` resets the limit; converging reviews carry on up to twice this |
| `review.model` | String: exact reviewer model identifier | Inherit the harness reviewer selection; default reviewer uses the first offered reviewer model that differs from the implementer's, else the agent CLI's default model | Must be in the review-specific offered models in Settings, not merely the agent model list |

Commands are run with `/bin/sh -c` from the repo's top folder, not from the config's folder.
The order is prepare, build, test, then additional checks; the first failure stops the run.
Command strings are repo-specific shell commands, not a finite list of supported command names.
Agent tool denials and protected paths still apply; config commands do not remove harness safety checks.

Context paths and globs select tracked files on the scanned default branch. An unmatched context entry
produces a warning; correct the path/glob, track the document, or remove that entry. These selectors
do not read untracked files. Protected paths and denied tools, unlike context, only extend the harness's
lists. The harness always denies agent push/fetch/pull/remote/config/stash operations, `gh` and network
installs, and protects its steering files and approved acceptance tests. Agents are told to use git
only to read history (`git log`, `git show`, `git diff`, `git status`).

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
the ledger names the models skipped and the one that reviewed. `No supported model available`, which
`auto` gives when it can't pick a model, counts as the chosen model not being available. An agent role
whose configured model isn't available runs with the CLI's default. The run's log starts with a note of
the switch. Reviews run within another role's run, so a review that fails says "The reviewer failed:".
A Copilot reviewer's output is kept in the artifacts as `<node>-<run>-<stage>-review.log`. An answer
without a valid JSON result gets the reviewer asked once more, logged in `…-review-retry.log`, before the
review fails; the failure then quotes the end of the last answer and names both logs. The prompt shows the
ticket's own tests in full, but other work's tests it updated only by path, since their changes are in the
diff: whole older suites can run to hundreds of kilobytes.
The strictest level among the overall policy and every declared or actually changed area applies.
A lower repo level, including an area below the overall level, is a start blocker. The effective
Review level and Reviewer rows each retain their own harness/repo source.

Before the acceptance-test review, a Swift package's tests are compiled. Errors only the tests can cause (syntax, clashing
names, a test nested in another test, a file named like another in the same test target) send them back to
the test author without using a review round; errors from API that doesn't exist yet are expected. That
includes a member the test author reported on a protocol but calls on a type that conforms to it, and calls
whose arguments don't match the current signature. A missing member of an existing type that the test author
didn't report counts as its own mistake. On such
a return the test author is told to make the smallest fix: every rewritten line risks a new mistake.
The test author builds and runs its own suite before finishing. Where the API its tests expect doesn't exist
yet, it adds placeholders (minimal bodies that compile, never a crash). Its new-behaviour tests should fail
against them, and its own helpers (fakes, renderers) must work. The harness then throws away everything it
changed outside the leaf's test folder (ignored build output stays) and commits only the tests. So helper
defects are found while writing the tests, not one implementer run at a time.
The one exception is other work's existing tests that this ticket's criteria deliberately supersede (say a
default that flips): the test author may update them with the smallest change and list them in
`updatedTests`. It changes only the lines the criterion requires, leaving the rest as it is even where it
breaks the rules for new tests (a fixed sleep, say), and restores anything it was asked to from git history
rather than from memory. Only listed files that aren't protected and lie in the test area, or in a folder
`leafTests.updatable` names, are kept; the implementer may change none of those. They're committed with
the acceptance tests, fingerprinted and locked like them, and named in the ticket comment. Work landing on
the requirement branch meanwhile may change them too: when the harness moves the leaf onto it (before building,
at landing, when catching up) and they were as locked just before, uncommitted changes aside, their lock
moves along. The reviewer rejects any such change no criterion requires. So the decomposer gives such
updates to the child whose change breaks those tests, as a criterion naming them and their new
expectation; it never makes the work wait for a person to change the repo first.
When the implementer reports a broken test (its own or, by `Suite.testName`, another item's that conflicts
with this ticket), the ticket goes back to the test author without charging an attempt. Since each report
costs a round, the implementer is told to run the whole suite first and report every conflicting test at once
(one in `testName`, the others in `reason`; a test outside the updatable folders goes in `testName`, so a
person is asked); the test author is told to fix each, and to check other tests
sharing a fixture or helper with the cause. The implementation
so far, committed or not, is kept on `agentos/kept-implementation/<node>` (without any changes to the test
area or the `leafTests.updatable` folders), and the implementer continues from it once the tests are fixed;
the comment says how many files were kept. Feedback with `harness:retry` after a person is asked keeps it too.
If it can't be kept, the tests aren't sent back: the ticket goes to
a person with the worktree unchanged. A person is asked
only on the third report about the same test, or the fifth about any tests, since a person last stepped in
(an answer, `harness:retry` or `harness:retest`): settled reports about other tests don't use up a test's
tries. The "Needs input" lists every report. A conflicting test that lives outside the test area and the
`leafTests.updatable` folders (a general test of the app, say) goes to a person on the first report: no
agent may change it, so a return can't settle it. On `harness:retry`, a conflicting test the test author
may now update (the repo has since added its folder, say), and which is still as committed when the ticket
started waiting, goes to the test author along with the answer. Otherwise, the person is taken to have fixed
the test, and the implementer tries again. A test that fails only sometimes (it passes when run again with
nothing changed) is flaky, not broken: the implementer is told not to report it. One that fails every time in
the whole suite but not on its own isn't flaky: the implementer fixes its change if that's the cause and
reports the conflict otherwise.
Later test-author rounds (for review findings, say) and the acceptance-test reviews get every broken-test
report since the tests last started over (`harness:retest` or a replan), including one a person sent back with
`harness:retry`. The author keeps the changes made
for them, fixtures and helpers included, and the reviewer counts a change to another work's test that settles
a report as required by the ticket rather than asking for it to be reverted: GH-88's fixture fix was undone
twice that way.
Whenever tests come back (compiler errors, review findings, a broken-test report), the leaf's new branch
starts from the landing branch with its earlier test folder restored, so the author fixes those tests in
place rather than rewriting them blind. Other work's tests the earlier runs updated are restored and kept
too, even when the fixing run doesn't list them again. `harness:retest` or a replan starts the tests over; feedback with
`harness:retry` keeps them, so the author applies the feedback to the earlier tests. Once the
tests are fixed again, the implementer no longer gets those reports about the earlier tests, so it doesn't
report a problem that's already been fixed.
The reviewer checks authored acceptance tests against the ticket before implementation starts. Weak
tests return to their author with findings, including any the reviewer filed as `testFindings`, along with
the findings of the earlier rounds of that review, which it is told to keep fixed. Criteria that behavioural
tests in the test folder can't prove (what documentation describes, file layout, code moved unchanged,
access levels, build settings) aren't held against the tests: the test author names them in its test file
instead of testing them, and the change review checks them against the diff. Passing tests therefore don't make a ticket "already
satisfied": the implementer may only claim that when the code meets every criterion, and a change with no
production edits is reviewed against the current source rather than its empty diff. After all landing checks pass, the reviewer receives the
ticket, complete diff against the landing branch, recent same-file history, and configured repository
rules. The built-in checklist covers regressions and loosened constraints, per-line/loop I/O and
allocation, duplicated logic, and tests that fail to prove the requirement. Rejected changes return to
the implementer without unlocking the acceptance tests. Their findings stay with the leaf until a new change
is submitted, so an implementer run that fails (a timeout, say) doesn't leave the retry without them. Since the implementer may not change them, the
reviewer lists problems in the ticket's own acceptance tests separately (`testFindings`), tests that are
missing included (a fix that needs a test to prove it is split: the fix in `findings`, the test in
`testFindings`): those send the
ticket back to the test author, keeping only its tests commit, and the implementer then builds again with
the remaining findings. Its implementation isn't lost: it's kept on `agentos/kept-implementation/<node>`,
and the implementer gets it back, uncommitted, to continue from once the tests are fixed. If it can't be
kept, the tests aren't sent back: the ticket goes to a person with the branch unchanged. Test findings go
to the test author even in the last review round, since the implementer couldn't act on them; only the
implementation findings count towards escalation then. If the implementer changes nothing for a review's findings (it may think they are
wrong, or about the tests), the harness doesn't submit the same branch for another review: it stops with
"Needs input". `harness:retest` then sends the ticket to the test author; a comment plus `harness:retry`
sends the answer to the implementer. After `maxRounds` reviews with findings at
either stage (default 2), work escalates, unless the reviews are converging: the latest round repeated
none of the earlier findings (all it found starts with "New:") and found no more problems than the round
before (one new problem after one fixed still counts). Converging work carries on, with a note on the ticket, up to twice `maxRounds`. Otherwise
the escalation lists the last round's findings as still open
and earlier rounds' as history, since the reviewer repeats any it still finds unfixed. A human
`harness:retry` resets the limit (from an escalation or from "Needs input"), and so does
`harness:retest`, since reviews of the discarded tests and code no longer count. A passing review at a
stage also starts its rounds over: work that comes back to that stage later (a broken test, say) is
reviewed afresh.

So that reviews converge, every review is asked to report all the blocking problems it finds at once,
and a later review round gets the findings of the earlier rounds at that stage.
The reviewer first checks each earlier finding is fixed. A new finding must be a defect that makes an
acceptance criterion fail or a regression the change introduced, and starts with "New:". Improvements,
out-of-scope and pre-existing problems go in `followUps`, and so does per-line or per-loop I/O unless it
makes a criterion fail: fixing it mid-review (with a cache, say) tends to bring new defects. The
implementer is told to fix findings with the simplest correct change, without new caches, shared state
or concurrency unless a finding asks for them. The harness posts follow-ups on the ticket for a
person to file as new tickets; they never fail the review. When the round limit is reached, the
escalation suggests splitting the ticket into smaller tickets.

**Run budget.** However its rounds are counted, a ticket that goes round between the test author and the
implementer stops once agents have run on it `limits.maxAgentRuns` times (default 12) since a person last
acted on it: it escalates with "Agents ran N times on this ticket since a person last acted on it". Any human
event on the ticket (a label such as `harness:retry`, an answer) starts a new budget.

**Diagnosis.** When a ticket escalates, a diagnoser agent reads its ledger history, copies of the last few
agent logs (not the rest of the log folder) and its worktree, and comments "🩺 Diagnosis" with a likely cause
and a suggested next step, such as splitting the ticket or giving the test author longer. It can't write
files or run commands. The ticket and logs are given to it as data, not instructions, and since the comment
is public it's told not to quote log lines, secrets, paths or environment variables; each part of its answer
is cut to 800 characters. Comments aren't held for approval, so on a public repo read diagnoses as you would
any agent output. It runs once per escalation and changes nothing: the ticket stays escalated, with its
original reason, until a person acts. A diagnoser that fails, times out or is stopped by a person is
recorded as such and not retried; one interrupted by closing the window or quitting runs again next time.
A person's `harness:retry`, `harness:retest` or `harness:replan` while the diagnoser runs stops it (no
comment is posted) and goes ahead; while any other agent runs on the ticket, these are turned away.

UI changes must include snapshot evidence and confirmation that windows actually open and close.
The implementer supplies `.agentos-ui-evidence.json` with `snapshotPaths`, `windowsOpened`,
`windowsClosed`, `beforeScreenshot` and `afterScreenshot`; file paths must refer to evidence inside
the worktree, outside the per-run scratch folder, in `.agentos-ui-evidence/`. Evidence is committed with
the leaf, so it is reviewed, reset and retried like its code, and the review only reads a
`.agentos-ui-evidence.json` the leaf itself changed. It never lands: the landing branch moves to a child of
the reviewed commit without the evidence, since on main it would be read as every later leaf's evidence.
The workspace copies those files to artifact storage so removing a landed worktree does not lose them. Agents and the tests they write never capture the
screen (`screencapture`, ScreenCaptureKit): agents run as the app's child processes, so macOS would ask
the person for Screen Recording permission on the app's behalf. They render views in their own process
instead: in a window that is never shown, with `cacheDisplay`, drawn onto opaque white before text
recognition (on a transparent background it reads nothing). The reviewer rejects tests that capture the
screen.

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
  snapshots/       detached main checkouts for decomposition, requirement checkouts for landing diagnosis
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
  `agentos/leaf/<node>`, started from its requirement's landing branch. A requirement is a top-level
  adopted ticket, including a top-level single leaf. Its branch `agentos/<ticket key>` is created from
  the current default branch when its first leaf starts building, and recorded in the ledger.
  Nested composites get no branch; every descendant leaf shares the top-level branch.
  Git runs with the harness's own exclude file, so build output is never committed
  even if the repo's `.gitignore` misses it. Uncommitted leftovers (e.g. a regenerated project file) are
  discarded before a rebase or rework. Every implementer run starts by rebasing the leaf onto the latest
  landing branch: its tests may have been written long before, and work landed since (often a dependency
  it waited for) must be there to build on. On a conflict the branch stays as it was and the landing queue
  sends it to rework.
- **Agents** get the repo's context in their prompt: the configured commands, where their tests go, and the
  protected paths. Only the test author's files in the leaf's own test folder, and older tests it updated
  and listed, are committed; whatever else it changed (placeholders to run its tests against) is thrown
  away first.
- **Checks** before landing: the leaf's tests (and older tests its test author updated) are unchanged
  since they were approved, no other leaf's tests changed, and no protected path changed. Then the leaf's tests (`test.only`), then all checks at landing.
  When only tests outside the leaf's own suite fail (another ticket's or a suite no ticket owns), the harness
  first runs the whole check again, unchanged. If that passes, it lands and reports an unreliable test.
  If it fails again, the failing suites of both runs are run alone (`test.only`, one suite at a time), with
  the change and on the latest requirement branch without it. These isolated runs only diagnose; they never land.
  - Failing on main too: a main/infrastructure problem, with no failed attempt; fix it and add `harness:retry`.
  - Failing alone with the change but not on main: a requirements conflict when every failing suite belongs
    to a proven ticket, otherwise the leaf's own failure.
  - Passing alone both ways: unreliable tests or interference under load (timing, say), not a conflict: the
    node stays in landing, escalated, with no failed attempt and no comment on the other tickets; make those
    tests reliable and add `harness:retry`.
  - A selection whose output says it ran no tests ("Test run with 0 tests", "Executed 0 tests") is an
    infrastructure problem (check `test.only`), not a pass. Without `test.only` the isolated run is the whole
    test command.

  Reports name the failing tests and include every rerun outcome.
- **Landing** is a fast-forward of the landing branch with `git update-ref` (compare-and-swap), so no checkout
  is involved. It's refused while any checkout has the landing branch checked out, because moving it there
  would make that working copy look modified.
- **Requirement isolation.** Each requirement branch contains only its own landed changes and catch-up
  work from `main`. Catch-up updates that branch and rebases only its idle active leaves. Bindings are
  restored from the ledger after restarting, including leaves already in progress before upgrading.
  The retired `agentos/main` is never used for building, landing or catch-up. Work already landed there
  stays only there: the readiness scan warns while it has commits absent from `main`. Merge
  `agentos/main` into `main` yourself; there is no automatic migration.
- **Copilot agents** run with `--allow-all-tools` plus a `--deny-tool` per effective denied tool (network
  installs as one `shell(…)` pattern) and per protected file (`write(AGENTS.md)`), and `--model` per role.
  Copilot's `write()` patterns only cover file names; folders and globs are enforced by the check above.
- **Unattended permissions.** Nobody can approve anything during a run, so the CLI denies whatever would
  need approval, and the agent tries another way at the cost of a turn. Paths are what gets denied: file
  paths are only checked to stay inside the worktree, not allowed outright (`--allow-all-paths` would remove
  the only file boundary on an unsandboxed machine). The CLI resolves a relative path from the worktree root
  and ignores `cd`, so `cd Sub && swift test > ../log` counts as outside. Agents are told to name such files,
  like their scratch folder, by absolute path. Each agent log ends with a line counting the run's denials and
  what they were, so anything agents keep needing shows up and can be allowed up front.
- **Which model ran.** Each agent log starts with the model and reasoning effort the run uses. When the harness
  chose none, it says "the CLI's default" with the defaults it can see as hints (`COPILOT_MODEL`, your settings in
  `$COPILOT_HOME/settings.json` or `~/.copilot/settings.json`): a repository default in a trusted folder overrides
  yours, so choose a model to be sure which runs. The ledger records the same with the run's claim
  (`agentConfigured`). A model the account can't use, or an effort the model doesn't support, is noted at the top
  of the log with what ran instead (another model, or the CLI's default effort), and the ledger gets a second
  `agentConfigured` with what ran and why. Falling back doesn't extend the run's timeout: all its attempts share
  it. A preview's breakdown is recorded the same way (without a claim, since a preview adopts nothing), keeps its
  log, and its comment names the model; a review records what it ran with in its review result.
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

  A preview runs in the background too, in one of the slots: the `harness:preview` label is answered at once
  with the run, model and reasoning effort, and the proposed breakdown (or the decomposer's questions) follows
  on the ticket when it's done. Meanwhile the preview is listed under Running now with its timer, model, effort,
  live log and Stop; stopping it, or a failure, is said on the ticket, and nothing is created either way. With
  every slot taken, the label stays on the ticket until a slot frees up; a second preview of a ticket whose
  preview is still running is refused. A preview cut off by a restart is reported on its ticket by the next
  round (the ledger records each preview's start and end: `previewStarted`, `previewFinished`). An approved
  breakdown is decomposed by a scheduled step, across rounds like other agents.

  Landing is the one kind of work that still holds its round open. It is synchronous and one at a time: the round that lands waits for the rebase, the landing checks
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
  role and time so far (a preview: its ticket, model and reasoning effort, with Stop and Log only), and offers:
  - **Stop**: cancels this exact run and waits for its task and child processes to end. The ledger and
    ticket name the person who stopped it; no failed attempt is counted. Add `harness:retry` to resume.
  - **Log**: the agent's output, followed live. Copilot writes each step as it goes (only the decomposer
    runs with `-s`, since its answer is parsed). The file is kept, and the node's details list every agent
    run with its log. Checks have no live log; theirs is recorded as evidence when they finish.
  - **Changes**: what the worktree changed since it left the landing branch, committed or not, including new
    files. Read with `git --no-optional-locks`, so looking never takes the index lock from an agent.
  - **Finder** and **Xcode**: the worktree itself. Look, don't change: anything changed there is committed
    as the agent's work.
- **Ledger browsing.** Repository and simulator windows show the newest 200 matching records, newest
  first. **Show older** adds 200 while more matches exist. **Ticket** offers **All tickets**, including
  node-less events, and exact ledger NodeIDs, including nodes absent from the current tracker. Known
  nodes use their canonical display names; unknown nodes show their IDs. A parent selection excludes
  descendants. **Event kind** offers **All event kinds** and each event case without its associated
  values. Filters combine with AND across the complete ledger before paging. Changing a filter resets
  the limit to 200; refresh preserves filters and the expanded limit, and empty matches clear the rows.
  The header always reports the exact complete ledger count. Refresh transfers bounded pages and new
  history records rather than copying complete history again; agent-run history remains complete and
  independently indexed. Simulator reset, restart and restore invalidate pages from the old ledger.
- **Run cleanup.** Pause prevents new rounds but lets the current work finish. Closing a repository
  window or quitting the app stops and awaits all its active agents and checks, recording why they
  ended. Opening a repository durably abandons old runs before readiness blockers are considered.
  A git command killed mid-write (a timeout, quitting) can leave a lock such as `index.lock` behind.
  When the harness's own git hits a lock file that no process has open, it removes it and runs the
  command once more; a lock some process still holds is left alone.
  Post-start errors always finish their run with the diagnostic. Checks that write nothing for
  10 minutes are ended as hung and retain their log; `CommandCheckRunner.idleTimeout` configures this
  limit independently of the 30-minute total timeout. Any output, including partial lines, resets it.
  A Copilot agent run is stopped after its role's timeout: built-in 20 minutes (10 for the diagnoser), set per
  role in Settings › Agents. A repo can change it per role with `agents.timeouts`, up to the longest timeout
  Settings allows (built-in an hour, at most 4 hours) and fails as "copilot timed out". Commands the agent
  started in their own process groups (Copilot runs each shell command in one) are ended with it, so a hung
  `swift test` can't keep holding the worktree's build lock for the next run.
  An implementer run that fails or is stopped before submitting (out of time, say) doesn't lose its work: its
  uncommitted changes are kept on the branch `agentos/unfinished/<node>`, out of reach of the next run's
  rebase and of catch-up. The next attempt gets them back, uncommitted, and is told to continue from them
  and to reuse the before screenshots already taken. They stay kept until that attempt ends: failing again
  keeps its changes instead; submitting or asking questions forgets them, and reporting a broken test moves
  them to the kept implementation (see the broken-test routing). A run that got them back and undid all of
  them before failing forgets them, so they don't come back again. Changes
  that no longer apply after the rebase are dropped. A new worktree (new tests, `harness:retest`) forgets
  them. If the changes can't be kept, the ticket goes to a person rather than to a retry that would clean
  them away. A run that ran out of time but left its work further along than it started (the kept changes
  differ from what it got back) isn't a failed attempt: the next run continues it. One that got no further
  counts, and the ticket's run budget (`maxAgentRuns`) still caps how often it goes round. A counted timeout is
  recorded with its unfinished work's fingerprint (not the agent's last output, which differs every time), so
  two timeouts leaving the same work are "the same failure twice".
  The test author's work is kept the same way: a test-author run that fails or is stopped leaves its test
  files as a draft in the worktree, recorded in the ledger (also when a person stops it). If tests an
  earlier run left uncommitted can't be kept as a draft, the ticket goes to a person and the worktree
  holding them stays as it is. Before the next attempt the harness checks the
  draft itself (does it build, which tests fail), and the test author is told to continue from the draft with
  that result instead of starting over. A draft that is accepted, or replaced by `harness:retest`, is
  forgotten.

Known limits: a leaf's tests go in the one configured test target, so if that target needs a simulator,
every leaf's checks do; picking a target per leaf (e.g. a package's tests for service-layer work) would
let those skip it. Tickets blocked by another system never unblock (there's no external system adapter
yet).

`agentos work [<repo>] [--ticket <title> --criterion <text>… --go]` runs it from the terminal until nothing
more can happen without a human. In the app, the repository window shows the tracker and work tree next to
the findings, policy and ledger, with Step and Run once nothing blocks agents. When only a missing or
out-of-date baseline blocks them, Run becomes **Run baseline, then Run** (a circular arrow around a small play
symbol): it runs the baseline on the current commit, rescans, and starts Run if nothing blocks agents then. A
baseline that fails on the current commit still needs a person.

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
  the requirement branch into `main` yourself. Nothing is pushed.
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
   - **Suggested answers:** under `autonomous`, when every question comes with a suggested answer, the work
     carries on with the suggestions and posts "💡 Proceeding on suggested answers", listing them once
     (assumptions that only restate one are dropped). The comment names only signals that work on the
     ticket: on a preview, correct a suggestion by commenting `2. Answer: <answer>` (one per line) and add
     `harness:preview`; on adopted work, comment and add `harness:retry`. `harness:breakdown` and
     `harness:go` refuse a preview when answers were given after it, so it never silently ignores them.
   - The decomposer runs in a read-only snapshot of `agentos/main` (a detached worktree, removed afterwards),
     so it reads the code and the repo's `AGENTS.md` when it splits the work. Anything it writes there is
     thrown away. If the snapshot can't be made, it splits from the ticket alone.
   - **Checked breakdowns:** after readiness and question handling, every fresh proposal is checked for
     vague rule references (such as "existing rule", "as agreed" or "see child"), path-based scope criteria
     (such as "Sources/Reader.swift is unchanged"), and siblings touching the same component without direct
     or transitive `after` ordering, and children with more than 6 acceptance criteria (more than one agent run
     can prove; even a single-child "leaf" proposal is checked for this), and the same criterion in several
     children (case, spacing and a closing full stop aside), which each child's test author would test
     again: a rule belongs to the child that builds it, and later children wait for it with `after`. Findings trigger exactly one decomposer retry with the prior proposal
     and structured findings, separate from human answers. A clean first proposal needs no retry.
     The second eligible proposal is used even if findings remain; there is never a third checker-driven call.
     Ownership wording does not suppress overlap findings: they remain advisory, so a person can accept
     a stated division of responsibility. Warnings do not open or revoke gates, stop already-authorized
     work, or become questions or assumptions.
   - Initial findings, the retry, and the second check's outcome (including a clean result) appear on the
     ticket and in ticket-keyed ledger events, even before adoption. Remaining warnings survive ledger
     replay with the preview. Adopting a matching preview creates its stored proposal without calling
     the decomposer or checker again and keeps the warning evidence. Each fresh preview or replan gets
     its own one-retry budget. Approve anyway with `harness:go`; for an adopted ticket, comment with
     corrections and add `harness:replan`. For an unadopted preview, comment or edit the ticket and add
     `harness:preview` instead. Previously stored previews without checker evidence remain readable.
   - The decomposer and test author return questions and assumptions with their result. Questions write
     `questionsRaised` and the `needs input` flag, and post a "❓ Needs input" comment with them. Tests
     written on a guess are thrown away. You answer in comments, then add `harness:retry`; without a
     comment after the question it's refused. The answer is recorded (`questionsAnswered`) and every agent
     working on the node or below it gets it as data: dated, oldest first, with later answers winning where
     they disagree. A comment containing `<!-- agentos:ignore -->` is a note for people (a diagnosis, a
     status update): it's never taken as an answer or a correction, nor shown to agents. Apart from
     answers, the decomposer and test author also see people's comments on the ticket and its parent
     (the newest, within a limit); the implementer doesn't, and works from the tests and answers. To give
     the implementer guidance, put it in the ticket's description or acceptance criteria.
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
   - **Closing an issue** stops the harness's work on it: no new steps, no landing, no status updates, and
     it leaves *Needs attention* (status *Closed*, unless already proven). A running agent finishes but its
     next step doesn't start. Its flags stay in the ledger, so **reopening** the issue brings them back. An
     issue missing from the open list is read once to confirm it's closed.
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
