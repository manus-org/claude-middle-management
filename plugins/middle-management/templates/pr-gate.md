# PR gate: <PR title>

Created: <YYYY-MM-DD HH:MM> · <model-id> · direct
Last updated: <YYYY-MM-DD HH:MM> · <model-id>

Branch: <head branch>

Copy this file as `pr-gate.md` into the folder that holds the PR body file, set `Branch:` to the
PR's head branch, and tick a box (`[x]`) only once it is true. One PR = one pr-gate.md; a second
PR from the same folder overwrites it. With `prGate: true` the PR gate hook holds `gh pr create`
until all seven boxes are ticked and `Branch:` names the branch being opened (review-loop step 7).

- [ ] Every `AGENTS.md` above a touched file walked rule by rule by a fresh reviewer, zero broken; the rules walked are listed in the PR body under `## Details`.
- [ ] The last review-loop round on this tip came back CLEAN: <report path>
- [ ] Every confirmed finding is fixed or decided by the user; none is left to the maintainer as "if you prefer".
- [ ] Every async path named in the plan (race, retry, late or stale answer, duplicate job, per-call timeout) has a test, or a written reason in the PR body.
- [ ] Checks ran one at a time, capped, touched packages only (or the full suite on the coordinator's call): <command> -> <result>
- [ ] Every new public method, export and published field is listed in the PR body.
- [ ] If stacked: the base PR has no unanswered maintainer review. Not stacked: tick it.
