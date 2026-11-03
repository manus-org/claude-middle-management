# Idea: the coordinator owns the test and review plan

Status: idea for the maintainer, not a finished design.

## Problem seen in practice

In two busy days of one project with 4 to 13 parallel lanes, each lane decided its own testing and
review:

- Tests took about a quarter of the lane time. Lanes spent about a third of their time waiting on
  tests.
- Most full-suite runs came after one changed file or none. Builder sub-agents re-ran the whole
  suite after almost every write. Reviewer sub-agents started their own full suites.
- The 4-round review loop ran on mechanical changes such as renames and doc wording, sometimes 3
  rounds in a few minutes.
- Parallel suites overloaded the shared machine: load above 30 on 8 cores, the swap was full, and
  the OOM killer stepped in.

All numbers are estimates from session transcripts.

## Idea

The coordinator already holds the big plan, so it should also decide when, what and how things
are tested and reviewed. Lanes should not each decide this on their own.

1. **A board section "Test & review plan"**, written by the coordinator. It sets the lane tier
   (touched test files only, once before READY), the round tier (one full suite plus one
   whole-system review after a few landings, before a paid or customer-visible step, at day end),
   and the exceptions (cross-cutting lanes may run the full suite, and that run is the round's
   suite).
2. **Every worker brief gets a `Tests:` and a `Review:` block** copied from that plan. `Review:` is
   `none`, `diff` (one round, fixes not re-reviewed) or `concept` (a loop on the plan before
   building). A worker never widens either block on its own.
3. **review-loop scope:** the loop runs once per coordinator round, or where a brief asks for it.
   Mechanical changes (rename, wording, docs, metadata, small config) get no round of their own.
   When a project has no plan, the old default (a loop per deliverable) stays.
4. **One READY line for tests:** `tests: <n> files, <passed>/<failed>, <s> s on <sha>` plus
   `review: none|<verdict>`. The full output goes to a file in the lane folder, never into the
   report.
5. **Optional, off by default:** a hook that denies full-suite commands in worker sessions unless
   the brief allows them. Projects can also serialise full suites on one machine with a file lock
   in their own test runner. That part belongs in the project, not in the plugin.

## Decided by the maintainer

- Pursue it as a plan for a later version. A project without a plan keeps today's default
  (point 3).
- The plan lives on the board, not in a separate config.
- A project's plan may override a global "review every deliverable" rule in CLAUDE.md, but only
  where the project explicitly has a plan. The maintainer makes that change in their own private
  settings, not in this plugin.

## Open for the maintainer

- Whether the review-loop skill reads the brief's `Review:` block itself, or only documents it.
