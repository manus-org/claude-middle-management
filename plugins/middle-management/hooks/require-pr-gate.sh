#!/usr/bin/env bash
# middle-management plugin: OPTIONAL PreToolUse hook (matcher Bash), OFF unless the config says
# "prGate": true. Consumers: hooks/hooks.json, tests/run.sh.
#
# A pull request opens only with its checklist complete (review-loop step 7): `gh pr create` is
# denied until `pr-gate.md` in the folder of the --body-file carries `Branch: <the head branch>`,
# no unticked box, and at least as many ticked boxes as templates/pr-gate.md has.
# Body file: `--body-file X`, `--body-file=X`, `-F X`; `~/` is expanded, a relative path is
# resolved against the base folder. `-` (stdin) or a path with a `$` in it is denied: the gate
# needs a literal file to look beside.
# Base folder: the last `cd <literal path>` earlier in the same command, else the tool call's cwd.
# Head branch: --head/-H, else `git -C <base folder> branch --show-current`; still unknown -> denied
# with "pass --head <branch>".
#
# Matching happens in COMMAND POSITION only (start, after ; && || | ( and the prefixes VAR=, sudo,
# env, nohup, time, timeout N, nice, a leading path), with the stripper of
# hooks/block-blanket-git-add.sh, changed in one way: quoted text is KEPT, its blanks and operators
# masked, so a quoted body path survives while `echo "gh pr create"` or a commit message that
# mentions it stays one word and never matches. A `\` line continuation joins the next line.
#
# Override for one PR, only on your user's word in this session (the deny reason says so):
# `MM_PR_GATE=off` as an assignment directly in front of that `gh pr create`, or in the hook's
# environment. A mention anywhere else (a --title, a commit message) does not count.
# Fails open (stays out of the way) when jq or awk is missing or the config is absent or invalid,
# the same as the other optional gates.
# Known bypasses (the gate raises the cost of skipping the checklist, it does not make skipping
# impossible): `gh api .../pulls -X POST`, gh inside a script, alias or `bash -lc '...'`, and a
# `<<` inside a quoted string, which turns on heredoc mode so the rest of the command is dropped.
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

# -> "<last cd target>\003<command>" per gh pr create in command position; inside quotes a blank
# is \001, an operator \002; a segment with MM_PR_GATE=off in its assignment prefix is not printed.
SEGS="$(printf '%s' "$CMD" | awk '
BEGIN {
  q    = sprintf("%c", 39)
  HDRE = "<<-?[ \t]*[" q "\"A-Za-z_][" q "\"A-Za-z0-9_]*"
  ASG  = "^[A-Za-z_][A-Za-z0-9_]*=[^ \t]*[ \t]*"
  PRE  = "^(sudo|env|nohup|time|nice|exec|command|then|do|else|elif|if|while|until|!)([ \t]+|$)"
  TMO  = "^timeout([ \t]+-[^ \t]+)*[ \t]+[0-9.]+[smhd]?([ \t]+|$)"
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
    s = seg[i]; sub(/^[ \t]+/, "", s); off = 0
    while (1) {
      if (s ~ ASG) { if (s ~ /^MM_PR_GATE=off([ \t]|$)/) off = 1; sub(ASG, "", s); continue }
      if (s ~ PRE) { sub(/^[^ \t]+[ \t]*/, "", s); continue }
      if (s ~ TMO) { sub(TMO, "", s); continue }
      if (s ~ /^[^ \t]*\//) { sub(/^[^ \t]*\//, "", s); continue }
      break
    }
    if (s ~ /^cd[ \t]+[^ \t]/) { cdd = s; sub(/^cd[ \t]+/, "", cdd); sub(/[ \t].*/, "", cdd) }
    if (!off && s ~ /^gh[ \t]+pr[ \t]+create([ \t]|$)/) print cdd "\003" s
  }
}' 2>/dev/null)"
[ -n "$SEGS" ] || exit 0

deny() {
  jq -n --arg r "PR gate (prGate): $1 Copy $TEMPLATE as pr-gate.md into the folder of the PR body file, set its Branch: line to the head branch, tick each box once it is true, then open the PR with gh pr create --body-file <that folder>/pr-body.md (review-loop step 7, skill middle-management:review-loop). Override: \`MM_PR_GATE=off gh pr create ...\` only on your user's word in this session." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

NEED="$(grep -cE '^[[:space:]]*- \[ \]' "$TEMPLATE" 2>/dev/null)"; [ "${NEED:-0}" -ge 1 ] || NEED=1
while IFS=$'\003' read -r DIR SEG; do
  read -ra T <<<"$SEG"
  BODY=""; HEAD=""; i=3
  while [ "$i" -lt "${#T[@]}" ]; do
    a="${T[$i]}"; nx="${T[$((i+1))]:-}"
    case "$a" in
      --body-file|-F) BODY="$nx"; i=$((i+1)) ;;
      --body-file=*)  BODY="${a#*=}" ;;
      --head|-H)      HEAD="$nx"; i=$((i+1)) ;;
      --head=*)       HEAD="${a#*=}" ;;
    esac
    i=$((i+1))
  done
  BODY="${BODY//$'\001'/ }"; DIR="${DIR//$'\001'/ }"; HEAD="${HEAD##*:}"
  case "$DIR" in "") BASE="$CWD" ;; *'$'*) BASE="" ;; "~/"*) BASE="$HOME/${DIR#\~/}" ;; /*) BASE="$DIR" ;; *) BASE="$CWD/$DIR" ;; esac
  [ -n "$BODY" ] || deny "gh pr create without --body-file: the gate looks for pr-gate.md beside the body file."
  case "$BODY" in -|*'$'*) deny "the body file is '$BODY': write the body to a literal path in your lane folder." ;; esac
  case "$BODY" in "~/"*) BODY="$HOME/${BODY#\~/}" ;; /*) ;; *) BODY="$BASE/$BODY" ;; esac
  GATE="$(dirname "$BODY")/pr-gate.md"
  [ -f "$GATE" ] || deny "no checklist at $GATE."
  [ -n "$HEAD" ] || [ -z "$BASE" ] || HEAD="$(git -C "$BASE" branch --show-current 2>/dev/null)"
  [ -n "$HEAD" ] || deny "could not read the head branch from '${BASE:-a cd the gate cannot follow}': pass --head <branch>."
  NAMED="$(sed -n 's/^Branch:[[:space:]]*//p' "$GATE" | head -1 | tr -d '`' | sed 's/[[:space:]]*$//')"
  [ -n "$NAMED" ] && [ "$NAMED" = "$HEAD" ] || deny "$GATE names branch '${NAMED:-none}', this PR is from '$HEAD': each PR gets its own checklist."
  OPEN="$(grep -cE '^[[:space:]]*- \[ \]' "$GATE")"
  DONE="$(grep -cE '^[[:space:]]*- \[[xX]\]' "$GATE")"
  [ "$OPEN" -eq 0 ] && [ "$DONE" -ge "$NEED" ] || deny "$GATE has $DONE of $NEED boxes ticked and $OPEN open."
done <<<"$SEGS"
exit 0
