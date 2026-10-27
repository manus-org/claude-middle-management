#!/usr/bin/env bash
# middle-management plugin: OPTIONAL PreToolUse hook (matcher Bash), OFF unless the config says
# "prGate": true. Consumers: hooks/hooks.json, tests/run.sh.
#
# A pull request opens only with its checklist complete (review-loop step 7): `gh pr create` (or its
# alias `gh pr new`) is denied until `pr-gate.md` in the folder of the --body-file carries
# `Branch: <the head branch>`, no unticked box, and at least as many ticked boxes as
# templates/pr-gate.md has. Head branch: --head/-H, else `git -C <cwd> branch --show-current`.
# Body file: `--body-file X`, `--body-file=X`, `-F X`, `-FX`; `~/` is expanded, a relative path is
# resolved against the tool call's cwd. `-` (stdin) or a path with a `$` in it is denied: the gate
# needs a literal file to look beside.
#
# Matching happens in COMMAND POSITION only (start, after ; && || | ( and the prefixes VAR=, sudo,
# env, a leading path), with the stripper of hooks/block-blanket-git-add.sh, changed in one way:
# quoted text is KEPT, its blanks and operators masked, so a quoted body path survives while
# `echo "gh pr create"` or a commit message that mentions it stays one word and never matches.
# A `\` line continuation joins the next line, so a multi-line `gh pr create \` is one command.
#
# Override for one PR: `MM_PR_GATE=off` in the command text or in the hook's environment, only on
# your user's word in this session (the deny reason says so).
# Fails open (stays out of the way) when jq or awk is missing or the config is absent or invalid,
# the same as the other optional gates.
# Known bypasses (the gate raises the cost of skipping the checklist, it does not make skipping
# impossible): `gh api .../pulls -X POST`, gh inside a script, alias or `bash -lc '...'`, and a `cd`
# earlier in the same command (a relative body path still resolves against the tool call's cwd).
# ponytail: a stripper instead of a parser; a `;|&(){}` inside a quoted path is not restored.
set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CHECK="$PLUGIN_ROOT/scripts/config-check.sh"
TEMPLATE="$PLUGIN_ROOT/templates/pr-gate.md"
command -v jq >/dev/null 2>&1 && command -v awk >/dev/null 2>&1 || exit 0
bash "$CHECK" validate || exit 0              # invalid or absent config: stay out of the way
[ "$(jq -r '.prGate // false' "$(bash "$CHECK" file)" 2>/dev/null)" = true ] || exit 0

INPUT="$(cat)"
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)"; [ -n "$CWD" ] || CWD="$PWD"
[ "${MM_PR_GATE:-}" = off ] && exit 0
printf '%s' "$CMD" | grep -qE '(^|[[:space:];&|(])MM_PR_GATE=off([[:space:];&|)]|$)' && exit 0

# -> one line per command in command position; inside quotes a blank is \001, an operator \002.
SEGS="$(printf '%s' "$CMD" | awk '
BEGIN {
  q    = sprintf("%c", 39)
  HDRE = "<<-?[ \t]*[" q "\"A-Za-z_][" q "\"A-Za-z0-9_]*"
  ASG  = "^[A-Za-z_][A-Za-z0-9_]*=[^ \t]*[ \t]*"
  PRE  = "^(sudo|env|nohup|time|nice|exec|command|then|do|else|elif|if|while|until|!)([ \t]+|$)"
  st = 0
}
function keep(c) { return c ~ /[ \t]/ ? "\001" : (c ~ /[;|&(){}`]/ ? "\002" : c) }
{
  line = $0
  if (hd != "") { t = line; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t); if (t == hd) hd = ""; next }
  if (match(line, HDRE) && substr(line, RSTART - 1, 1) != "<") {
    d = substr(line, RSTART, RLENGTH); sub(/^<<-?[ \t]*/, "", d); gsub("[" q "\"]", "", d); hd = d
  }
  out = ""; cont = 0
  for (i = 1; i <= length(line); i++) {
    c = substr(line, i, 1)
    if (st == 1) { if (c == q) st = 0; else out = out keep(c); continue }
    if (st == 2) {
      if (c == "\\") { i++; out = out keep(substr(line, i, 1)); continue }
      if (c == "\"") st = 0; else out = out keep(c); continue
    }
    if (c == "\\") { if (i == length(line)) cont = 1; else out = out keep(substr(line, i + 1, 1)); i++; continue }
    if (c == q)    { st = 1; continue }
    if (c == "\"") { st = 2; continue }
    if (c == "#" && (out == "" || substr(out, length(out), 1) ~ /[ \t;&|(]/)) break
    out = out c
  }
  buf = buf out (cont ? " " : (st ? "\001" : "\n"))
}
END {
  txt = buf
  gsub(/[0-9]*[<>]&[0-9-]*/, " ", txt)
  gsub(/&>>?/, " ", txt)
  gsub(/[;|&(){}`]/, "\n", txt)
  n = split(txt, seg, "\n")
  for (i = 1; i <= n; i++) {
    s = seg[i]; sub(/^[ \t]+/, "", s)
    while (1) {
      if (s ~ ASG) { sub(ASG, "", s); continue }
      if (s ~ PRE) { sub(/^[^ \t]+[ \t]*/, "", s); continue }
      if (s ~ /^[^ \t]*\//) { sub(/^[^ \t]*\//, "", s); continue }
      break
    }
    if (s ~ /^gh[ \t]+pr[ \t]+(create|new)([ \t]|$)/) print s
  }
}' 2>/dev/null)"
[ -n "$SEGS" ] || exit 0

deny() {
  jq -n --arg r "PR gate (prGate): $1 Copy $TEMPLATE as pr-gate.md into the folder of the PR body file, set its Branch: line to the head branch, tick each box once it is true, then open the PR with gh pr create --body-file <that folder>/pr-body.md (review-loop step 7, skill middle-management:review-loop). Override: \`MM_PR_GATE=off gh pr create ...\` only on your user's word in this session." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

NEED="$(grep -cE '^[[:space:]]*- \[ \]' "$TEMPLATE" 2>/dev/null)"; [ "${NEED:-0}" -ge 1 ] || NEED=1
while IFS= read -r SEG; do
  read -ra T <<<"$SEG"
  BODY=""; HEAD=""; i=3
  while [ "$i" -lt "${#T[@]}" ]; do
    a="${T[$i]}"; nx="${T[$((i+1))]:-}"
    case "$a" in
      --body-file|-F) BODY="$nx"; i=$((i+1)) ;;
      --body-file=*)  BODY="${a#*=}" ;;
      -F?*)           BODY="${a#-F}" ;;
      --head|-H)      HEAD="$nx"; i=$((i+1)) ;;
      --head=*)       HEAD="${a#*=}" ;;
      -H?*)           HEAD="${a#-H}" ;;
    esac
    i=$((i+1))
  done
  BODY="${BODY//$'\001'/ }"; HEAD="${HEAD##*:}"
  [ -n "$BODY" ] || deny "gh pr create without --body-file: the gate looks for pr-gate.md beside the body file."
  case "$BODY" in -|*'$'*) deny "the body file is '$BODY': write the body to a literal path in your lane folder." ;; esac
  case "$BODY" in "~/"*) BODY="$HOME/${BODY#\~/}" ;; /*) ;; *) BODY="$CWD/$BODY" ;; esac
  GATE="$(dirname "$BODY")/pr-gate.md"
  [ -f "$GATE" ] || deny "no checklist at $GATE."
  [ -n "$HEAD" ] || HEAD="$(git -C "$CWD" branch --show-current 2>/dev/null)"
  NAMED="$(sed -n 's/^Branch:[[:space:]]*//p' "$GATE" | head -1 | tr -d '`' | sed 's/[[:space:]]*$//')"
  [ -n "$NAMED" ] && [ "$NAMED" = "$HEAD" ] || deny "$GATE names branch '${NAMED:-none}', this PR is from '${HEAD:-unknown}': each PR gets its own checklist."
  OPEN="$(grep -cE '^[[:space:]]*- \[ \]' "$GATE")"
  DONE="$(grep -cE '^[[:space:]]*- \[[xX]\]' "$GATE")"
  [ "$OPEN" -eq 0 ] && [ "$DONE" -ge "$NEED" ] || deny "$GATE has $DONE of $NEED boxes ticked and $OPEN open."
done <<<"$SEGS"
exit 0
