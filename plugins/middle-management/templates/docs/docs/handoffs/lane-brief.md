# Lane brief: <topic>

Created: <YYYY-MM-DD HH:MM> · <model-id> · direct
Last updated: <YYYY-MM-DD HH:MM> · <model-id>

## Goal

<One sentence: what the lane achieves for whom.>

## Acceptance criteria

<One line each. The reviewer gets these verbatim, so each one is checkable.>

## Repo rules

<Every `AGENTS.md` above the paths this lane touches: the repo root plus each touched app or
package, by absolute path.> These win over house rules, comment markers included (use the repo's
own marker for a deliberate shortcut). Every line of this brief agrees with them.

## Build

Each async path the plan names (race, retry, late or stale answer, duplicate job, per-call
timeout) gets a test.

## Checks

Every check the lane runs (touched packages, or the full suite when the coordinator calls for it)
runs one at a time with `--concurrency=1` through `/wt cap` or your capped wrapper; type-checks
run one after another. A repo whose pre-push hook runs the checks in parallel: run the hook's own
check command one at a time through the capped wrapper first (same filter, `--concurrency=1`),
then push with the hook skipped (lefthook: `LEFTHOOK=0 git push`).

## Review

The review-loop skill runs until a CLEAN round. The builder's deviation list sits in a file the
reviewer opens only after its own walk is written.

## Before the PR

Review-loop step 7 and a complete `pr-gate.md` beside the PR body file. A PR stacks only on a base
PR whose maintainer review is answered.
