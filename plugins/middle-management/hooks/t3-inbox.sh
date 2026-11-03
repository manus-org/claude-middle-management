#!/usr/bin/env bash
# middle-management plugin: PostToolUse + UserPromptSubmit hook, quiet worker reports handed into the
# T3 coordinator's own turn (README "Quiet reports", 0.15.0).
# Consumers: hooks/hooks.json (PostToolUse and UserPromptSubmit registrations), tests/t3-inbox.sh.
#   Calls scripts/t3-inbox.py inject; reads the sessionId of <marker dir>/orchestrator.t3.json.
#
# Runs on every tool call of every session, so the common case ends in bash builtins: no T3 thread,
# or no item in any scope's inbox (<config dir>/state[/scopes/*]/t3-inbox/*.json), or no inbox whose
# sidecar names this session -> exit 0. Only the coordinator, while reports wait, starts
# t3-inbox.py, which skips a sub-agent's tool call (agent_id), prints the reports as
# additionalContext and deletes exactly what it printed. The sidecar's "previous" holder (written
# last, scripts/orchestrator.sh t3-bind) is cut off before the match, so a former coordinator stays
# on the fast path.
# ponytail: no config-check.sh (two forks per tool call): the config dir is resolved inline, the same
# rule. The hook input is read only once an item waits ($(cat) is one fork; read -d '' would go byte
# by byte through a large tool response).
set -u
[ -n "${T3CODE_HOME:-}" ] || exit 0
ST="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/state"
shopt -s nullglob
F=("$ST"/t3-inbox/*.json "$ST"/scopes/*/t3-inbox/*.json)
[ "${#F[@]}" -gt 0 ] || exit 0
IN=$(cat)
RE='"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9-]+)"'
[[ ${IN:0:4096} =~ $RE ]] || [[ $IN =~ $RE ]] || exit 0
SID=${BASH_REMATCH[1]}
D=""
for f in "${F[@]}"; do
  d=${f%/t3-inbox/*}; [ "$d" = "$D" ] && continue; D=$d   # the glob is sorted: one check per dir
  X=""; IFS= read -r -d '' X 2>/dev/null < "$d/orchestrator.t3.json"; X=${X%%\"previous\"*}
  if [[ $X =~ \"sessionId\"[[:space:]]*:[[:space:]]*\"$SID\" ]]; then
    printf '%s' "$IN" | python3 "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/scripts/t3-inbox.py" inject
    exit 0
  fi
done
exit 0
