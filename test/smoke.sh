#!/usr/bin/env bash
# smoke.sh — end-to-end protocol test, no herdr required.
#
# Builds a throwaway project with a coder (task mode) and cleaner (batch
# mode), then drives a full handoff lifecycle both directions:
#   draft -> swarm_handoff -> handoffd --once -> ready_for_next ->
#   done_with_current, plus validation-failure and batch cases.
set -euo pipefail

TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
if command -v cygpath >/dev/null 2>&1; then WORK="$(cygpath -m "$WORK")"; TOOL_ROOT="$(cygpath -m "$TOOL_ROOT")"; fi
trap 'rm -rf "$WORK"' EXIT
export SWARMFORGE_WAKE_CMD=none

PASS=0
step() { echo "--- $1"; }
ok() { PASS=$((PASS + 1)); echo "ok: $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }
expect() { # expect <label> <needle> <<< haystack
  local haystack; haystack="$(cat)"
  grep -qF "$2" <<<"$haystack" || { echo "$haystack"; fail "$1 (missing: $2)"; }
  ok "$1"
}

step "installed prompts match their sources"
# This repo dogfoods itself, so swarmforge/ holds installed copies of the
# stock prompts. Drift there means a fix landed in prompts/ and never
# reached the swarm actually running on it. Two categories are excluded
# deliberately: project.prompt is written per project, and contracts carry
# project-specific artifact roots and evidence patterns. pack.prompt is a
# copy of whichever pack is installed, so it is matched against the set.
same_as_source() { # same_as_source <installed-rel> <source-rel>
  if [ ! -f "$TOOL_ROOT/$2" ]; then
    ok "$1 has no stock source (project-authored)"
    return
  fi
  diff -q "$TOOL_ROOT/$1" "$TOOL_ROOT/$2" >/dev/null 2>&1 || {
    diff -u "$TOOL_ROOT/$2" "$TOOL_ROOT/$1" >&2 || true
    fail "$1 drifted from $2 — edit prompts/ as source, then sync both"
  }
  ok "$1 matches $2"
}
same_as_source swarmforge/constitution.prompt prompts/constitution.prompt
same_as_source swarmforge/worker-common.prompt prompts/worker-common.prompt
for a in engineering handoffs workflow; do
  same_as_source "swarmforge/constitution/articles/$a.prompt" \
                 "prompts/articles/$a.prompt"
done
for r in "$TOOL_ROOT"/swarmforge/roles/*.prompt; do
  n="$(basename "$r")"
  same_as_source "swarmforge/roles/$n" "prompts/roles/$n"
done
PACK_OK=0
for p in "$TOOL_ROOT"/packs/*.prompt; do
  diff -q "$TOOL_ROOT/swarmforge/constitution/articles/pack.prompt" "$p" \
    >/dev/null 2>&1 && PACK_OK=1
done
[ "$PACK_OK" -eq 1 ] || fail "installed pack.prompt matches no packs/*.prompt"
ok "installed pack.prompt matches a pack article"

# A new kind of installed file must be classified, not silently ignored:
# either it is compared above or it is a documented per-project file.
while read -r rel; do
  case "$rel" in
    constitution.prompt|worker-common.prompt|roles/*.prompt) continue ;;
    constitution/articles/engineering.prompt) continue ;;
    constitution/articles/handoffs.prompt) continue ;;
    constitution/articles/workflow.prompt) continue ;;
    constitution/articles/pack.prompt) continue ;;
    constitution/articles/project.prompt) continue ;;  # per project
    constitution/articles/toolset.prompt) continue ;;  # generated
    contracts/*.contract.edn) continue ;;              # per project
    swarmforge.conf) continue ;;                       # per project
  esac
  fail "unclassified installed file swarmforge/$rel — compare it or document it"
done < <(cd "$TOOL_ROOT/swarmforge" && find . -type f -not -path './scripts/*' \
           | sed 's|^\./||' | sort)
ok "every installed file is compared or documented"

step "set up throwaway project"
PROJECT="$WORK/project"
mkdir -p "$PROJECT"
git -C "$PROJECT" init -qb main
git -C "$PROJECT" -c user.email=smoke@test -c user.name=smoke \
  commit -q --allow-empty -m "initial"
COMMIT="$(git -C "$PROJECT" rev-parse --short=10 HEAD)"

step "launcher protects main from a project-root coder"
PROTECTED="$WORK/protected"
mkdir -p "$PROTECTED/swarmforge"
git -C "$PROTECTED" init -qb main
git -C "$PROTECTED" -c user.email=smoke@test -c user.name=smoke \
  commit -q --allow-empty -m "initial"
printf 'window coder codex master task\n' > "$PROTECTED/swarmforge/swarmforge.conf"
set +e
OUT="$(cd "$PROTECTED" && "$TOOL_ROOT/bin/swarm" up 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 1 ] || fail "protected-branch launch should exit 1, got $STATUS"
expect "protected branch: launch rejected" \
  "Refusing to start coder in the project root on protected branch 'main'." <<<"$OUT"
[ ! -d "$PROTECTED/.worktrees" ] || fail "rejected launch should create no worktrees"
ok "protected branch rejection happens before worktree creation"

step "review-gated Codex pack isolates both roles"
REVIEW_PACK="$WORK/review-pack"
mkdir -p "$REVIEW_PACK"
git -C "$REVIEW_PACK" init -qb main
git -C "$REVIEW_PACK" -c user.email=smoke@test -c user.name=smoke \
  commit -q --allow-empty -m "initial"
(cd "$REVIEW_PACK" && "$TOOL_ROOT/bin/swarm" init adversaries-codex-review >/dev/null)
grep -q '^window coder codex candidate task ' \
  "$REVIEW_PACK/swarmforge/swarmforge.conf" \
  || fail "review-gated coder should use the candidate worktree"
grep -q '^window reviewer codex reviewer task ' \
  "$REVIEW_PACK/swarmforge/swarmforge.conf" \
  || fail "review-gated reviewer should use the reviewer worktree"
ok "review-gated pack keeps coder and reviewer out of the project root"

step "all-models six-pack pins benchmark-selected roles"
ALL_MODELS_PACK="$WORK/all-models-pack"
mkdir -p "$ALL_MODELS_PACK"
git -C "$ALL_MODELS_PACK" init -qb main
git -C "$ALL_MODELS_PACK" -c user.email=smoke@test -c user.name=smoke \
  commit -q --allow-empty -m "initial"
(cd "$ALL_MODELS_PACK" && \
  "$TOOL_ROOT/bin/swarm" init six-all-models-review >/dev/null && \
  "$TOOL_ROOT/bin/swarm" switch six-codex-review >/dev/null && \
  "$TOOL_ROOT/bin/swarm" switch six-all-models-review >/dev/null)
ALL_MODELS_CONF="$ALL_MODELS_PACK/swarmforge/swarmforge.conf"
grep -q '^window specifier claude all-specifier task --model claude-opus-5 --effort xhigh$' \
  "$ALL_MODELS_CONF" \
  || fail "all-models specifier should pin Opus 5 xHigh"
grep -q '^window coder codex all-coder task --model gpt-5.6-sol -c model_reasoning_effort=high ' \
  "$ALL_MODELS_CONF" \
  || fail "all-models coder should pin Sol High"
grep -q '^window cleaner claude all-cleaner batch --model claude-opus-5 --effort high$' \
  "$ALL_MODELS_CONF" \
  || fail "all-models cleaner should pin Opus 5 High"
grep -q '^window architect claude all-architect batch --model claude-opus-5 --effort xhigh$' \
  "$ALL_MODELS_CONF" \
  || fail "all-models architect should pin Opus 5 xHigh"
grep -q '^window hardener grok all-hardener batch --model grok-4.6 --reasoning-effort high ' \
  "$ALL_MODELS_CONF" \
  || fail "all-models hardener should pin Grok 4.6 High"
grep -q '^window qa codex all-qa batch --model gpt-5.6-sol -c model_reasoning_effort=xhigh ' \
  "$ALL_MODELS_CONF" \
  || fail "all-models qa should pin Sol xHigh"
grep -q 'Only the operator' \
  "$ALL_MODELS_PACK/swarmforge/constitution/articles/pack.prompt" \
  || fail "all-models pack should retain the human integration gate"
ok "all-models six-pack is invokable with pinned isolated roles"

step "Claude and Codex six-pack pins benchmark-informed roles"
CLAUDE_CODEX_PACK="$WORK/claude-codex-pack"
mkdir -p "$CLAUDE_CODEX_PACK"
git -C "$CLAUDE_CODEX_PACK" init -qb main
git -C "$CLAUDE_CODEX_PACK" -c user.email=smoke@test -c user.name=smoke \
  commit -q --allow-empty -m "initial"
(cd "$CLAUDE_CODEX_PACK" && \
  "$TOOL_ROOT/bin/swarm" init six-claude-codex-review >/dev/null && \
  "$TOOL_ROOT/bin/swarm" switch six-codex-review >/dev/null && \
  "$TOOL_ROOT/bin/swarm" switch six-claude-codex-review >/dev/null)
CLAUDE_CODEX_CONF="$CLAUDE_CODEX_PACK/swarmforge/swarmforge.conf"
grep -q '^window specifier claude cc-specifier task --model claude-opus-5 --effort xhigh$' \
  "$CLAUDE_CODEX_CONF" \
  || fail "Claude-Codex specifier should pin Opus 5 xHigh"
grep -q '^window coder codex cc-coder task --model gpt-5.6-sol -c model_reasoning_effort=high ' \
  "$CLAUDE_CODEX_CONF" \
  || fail "Claude-Codex coder should pin Sol High"
grep -q '^window cleaner claude cc-cleaner batch --model claude-opus-5 --effort high$' \
  "$CLAUDE_CODEX_CONF" \
  || fail "Claude-Codex cleaner should pin Opus 5 High"
grep -q '^window architect claude cc-architect batch --model claude-opus-5 --effort xhigh$' \
  "$CLAUDE_CODEX_CONF" \
  || fail "Claude-Codex architect should pin Opus 5 xHigh"
grep -q '^window hardener claude cc-hardener batch --model claude-opus-5 --effort xhigh$' \
  "$CLAUDE_CODEX_CONF" \
  || fail "Claude-Codex hardener should pin Opus 5 xHigh"
grep -q '^window qa codex cc-qa batch --model gpt-5.6-sol -c model_reasoning_effort=xhigh ' \
  "$CLAUDE_CODEX_CONF" \
  || fail "Claude-Codex QA should pin Sol xHigh"
CLAUDE_CODEX_PROMPT="$CLAUDE_CODEX_PACK/swarmforge/constitution/articles/pack.prompt"
grep -q 'output or security probe' "$CLAUDE_CODEX_PROMPT" \
  || fail "Claude-Codex pack should require executable output and security probes"
grep -q 'Only the operator' "$CLAUDE_CODEX_PROMPT" \
  || fail "Claude-Codex pack should retain the human integration gate"
ok "Claude and Codex six-pack is invokable with pinned isolated roles"

CODER="$PROJECT"
CLEANER="$WORK/cleaner"
mkdir -p "$CLEANER"
mkdir -p "$PROJECT/.swarmforge"
printf 'coder\tmaster\t%s\tcoder\tcoder\tclaude\ttask\ncleaner\tcleaner\t%s\tcleaner\tcleaner\tclaude\tbatch\n' \
  "$CODER" "$CLEANER" > "$PROJECT/.swarmforge/roles.tsv"
# The cleaner "worktree" needs to resolve the project root and the commit.
printf 'gitdir: %s
' "$(cygpath -w "$PROJECT/.git" 2>/dev/null || echo "$PROJECT/.git")" > "$CLEANER/.git"
ln -s "$PROJECT/.swarmforge" "$CLEANER/.swarmforge" 2>/dev/null || true
rm -rf "$CLEANER/.swarmforge"; mkdir -p "$CLEANER/.swarmforge"
cp "$PROJECT/.swarmforge/roles.tsv" "$CLEANER/.swarmforge/roles.tsv"
for wt in "$CODER" "$CLEANER"; do
  mkdir -p "$wt/swarmforge"
  cp -r "$TOOL_ROOT/swarmforge/scripts" "$wt/swarmforge/scripts"
done
SCRIPTS="swarmforge/scripts"

step "reject an invalid draft"
cd "$CODER"
printf 'type: git_handoff\nto: nobody\npriority: high\ncommit: xyz\n' > draft.txt
set +e
OUT="$(SWARMFORGE_ROLE=coder "$SCRIPTS/swarm_handoff.sh" draft.txt 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "invalid draft should exit 2, got $STATUS"
expect "invalid draft: bad priority reported" "must be two digits" <<<"$OUT"
expect "invalid draft: unknown recipient reported" "Unknown recipient role 'nobody'" <<<"$OUT"
expect "invalid draft: missing task reported" "Missing required header 'task'" <<<"$OUT"
rm draft.txt

step "queue a valid git_handoff (coder -> cleaner)"
printf 'type: git_handoff\nto: cleaner\npriority: 50\ntask: smoke-task\ncommit: %s\n' "$COMMIT" > draft.txt
OUT="$(SWARMFORGE_ROLE=coder "$SCRIPTS/swarm_handoff.sh" draft.txt)"
expect "handoff queued" "HANDOFF QUEUED:" <<<"$OUT"
[ ! -e draft.txt ] || fail "draft should be deleted after queuing"
ok "draft removed"

step "deliver via handoffd --once"
bb "$SCRIPTS/handoffd.bb" "$PROJECT" --once
[ -n "$(ls "$CLEANER/.swarmforge/handoffs/inbox/new/" 2>/dev/null)" ] || fail "no inbox delivery"
[ -n "$(ls "$CODER/.swarmforge/handoffs/sent/" 2>/dev/null)" ] || fail "original not archived to sent/"
ok "delivered to cleaner inbox, archived to coder sent/"
INBOX_FILE="$(ls "$CLEANER"/.swarmforge/handoffs/inbox/new/*.handoff)"
grep -q '^recipient: cleaner$' "$INBOX_FILE" || fail "recipient header missing"
grep -q '^enqueued_at: ' "$INBOX_FILE" || fail "enqueued_at header missing"
ok "delivery headers stamped"

step "queue a second handoff at the same priority (for batching)"
printf 'type: note\nto: cleaner\npriority: 50\nmessage: smoke note\n' > draft.txt
SWARMFORGE_ROLE=coder "$SCRIPTS/swarm_handoff.sh" draft.txt > /dev/null
bb "$SCRIPTS/handoffd.bb" "$PROJECT" --once

step "cleaner accepts both as one batch"
cd "$CLEANER"
OUT="$(SWARMFORGE_ROLE=cleaner "$SCRIPTS/ready_for_next.sh")"
expect "batch accepted" "BATCH:" <<<"$OUT"
expect "batch has two items" "COUNT: 2" <<<"$OUT"
expect "batch carries payload" "merge_and_process coder" <<<"$OUT"
expect "batch carries note" "smoke note" <<<"$OUT"

step "ready_for_next resumes the same batch"
OUT="$(SWARMFORGE_ROLE=cleaner "$SCRIPTS/ready_for_next.sh")"
expect "batch resumed" "COUNT: 2" <<<"$OUT"

step "cleaner completes the batch and returns a handoff"
OUT="$(SWARMFORGE_ROLE=cleaner "$SCRIPTS/done_with_current.sh")"
expect "batch completed" "COMPLETED_BATCH:" <<<"$OUT"
expect "queue drained" "NO_TASK" <<<"$OUT"
printf 'type: git_handoff\nto: coder\npriority: 50\ntask: smoke-task\ncommit: %s\n' "$COMMIT" > return.txt
SWARMFORGE_ROLE=cleaner "$SCRIPTS/swarm_handoff.sh" return.txt > /dev/null
bb "$SCRIPTS/handoffd.bb" "$PROJECT" --once

step "coder accepts and completes the return handoff (task mode)"
cd "$CODER"
OUT="$(SWARMFORGE_ROLE=coder "$SCRIPTS/ready_for_next.sh")"
expect "task accepted" "TASK:" <<<"$OUT"
expect "task named" "TASK_NAME: smoke-task" <<<"$OUT"
OUT="$(SWARMFORGE_ROLE=coder "$SCRIPTS/done_with_current.sh")"
expect "task completed" "COMPLETED:" <<<"$OUT"
expect "coder queue drained" "NO_TASK" <<<"$OUT"

step "contract enforcement: violations hard-block, compliance passes"
mkdir -p "$CODER/swarmforge/contracts"
cat > "$CODER/swarmforge/contracts/coder.contract.edn" <<'EDN'
{:role "coder"
 :artifact-roots ["src/"]
 :required-evidence [{:name "tests-green" :pattern "(?i)tests? passed"}]}
EDN
mkdir -p src && echo x > src/ok.txt && echo y > forbidden.txt
git add src forbidden.txt
git -c user.email=smoke@test -c user.name=smoke commit -qm "bad commit, no evidence"
BAD="$(git rev-parse --short=10 HEAD)"
printf 'type: git_handoff\nto: cleaner\npriority: 50\ntask: contract-check\ncommit: %s\n' "$BAD" > draft.txt
set +e
OUT="$(SWARMFORGE_ROLE=coder "$SCRIPTS/swarm_handoff.sh" draft.txt 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "contract violation should exit 2, got $STATUS"
expect "contract: out-of-root path rejected" "outside role coder's artifact roots" <<<"$OUT"
expect "contract: missing evidence rejected" "required evidence 'tests-green'" <<<"$OUT"
echo z >> src/ok.txt && git add src
git -c user.email=smoke@test -c user.name=smoke commit -qm "good commit

All 5 tests passed."
GOOD="$(git rev-parse --short=10 HEAD)"
printf 'type: git_handoff\nto: cleaner\npriority: 50\ntask: contract-check\ncommit: %s\n' "$GOOD" > draft.txt
OUT="$(SWARMFORGE_ROLE=coder "$SCRIPTS/swarm_handoff.sh" draft.txt)"
expect "contract: compliant commit queues" "HANDOFF QUEUED:" <<<"$OUT"
rm -f draft.txt
rm -rf "$CODER/swarmforge/contracts"

step "squad: hostile worker names are rejected before path resolution"
set +e
OUT="$("$SCRIPTS/squad_worker.sh" retire '../assignments/a1/status' 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "traversal name should exit 2, got $STATUS"
expect "traversal worker name rejected" "INVALID_WORKER_NAME" <<<"$OUT"

step "done with nothing in process fails cleanly"
set +e
OUT="$(SWARMFORGE_ROLE=coder "$SCRIPTS/done_with_current.sh" 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 1 ] || fail "empty done should exit 1, got $STATUS"
expect "empty done reports NO_CURRENT_TASK" "NO_CURRENT_TASK" <<<"$OUT"

step "squad: create/status/result/accept lifecycle"
cd "$CODER"
echo "Implement the thing." > instructions.md
OUT="$("$SCRIPTS/squad_assign.sh" create a1 implementer instructions.md)"
expect "assignment created" "ASSIGNMENT_CREATED: a1" <<<"$OUT"
[ -f .swarmforge/squad/assignments/a1/assignment.md ] || fail "assignment.md not written"
ok "assignment.md written"
OUT="$("$SCRIPTS/squad_assign.sh" status a1)"
expect "status reports created" "STATE: created" <<<"$OUT"
echo "worker output" > worker.handoff
OUT="$("$SCRIPTS/squad_assign.sh" result a1 worker.handoff)"
expect "result transition" "ASSIGNMENT_STATE: a1 created -> result" <<<"$OUT"
[ -f .swarmforge/squad/assignments/a1/result.handoff ] || fail "result handoff not stored"
ok "result handoff stored"
OUT="$("$SCRIPTS/squad_assign.sh" accept a1)"
expect "accept transition" "ASSIGNMENT_STATE: a1 result -> accepted" <<<"$OUT"

step "squad: reject records the reason"
"$SCRIPTS/squad_assign.sh" create a2 implementer instructions.md > /dev/null
"$SCRIPTS/squad_assign.sh" result a2 worker.handoff > /dev/null
OUT="$("$SCRIPTS/squad_assign.sh" reject a2 missing unit tests)"
expect "reject transition" "ASSIGNMENT_STATE: a2 result -> rejected" <<<"$OUT"
OUT="$("$SCRIPTS/squad_assign.sh" status a2)"
expect "status reports rejected" "STATE: rejected" <<<"$OUT"
expect "status carries reason" "REASON: missing unit tests" <<<"$OUT"

step "squad: illegal transition exits 2 with INVALID_TRANSITION"
set +e
OUT="$("$SCRIPTS/squad_assign.sh" accept a1 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "illegal transition should exit 2, got $STATUS"
expect "illegal transition token" "INVALID_TRANSITION" <<<"$OUT"

step "squad: replace links old and new assignments"
OUT="$("$SCRIPTS/squad_assign.sh" replace a2 a3 implementer instructions.md)"
expect "replacement announced" "ASSIGNMENT_REPLACED: a2 -> a3" <<<"$OUT"
OUT="$("$SCRIPTS/squad_assign.sh" status a2)"
expect "old links forward" "REPLACED_BY: a3" <<<"$OUT"
OUT="$("$SCRIPTS/squad_assign.sh" status a3)"
expect "new links back" "REPLACES: a2" <<<"$OUT"
expect "new starts created" "STATE: created" <<<"$OUT"

step "squad: events.log holds one timestamped line per state change"
LOG="$CODER/.swarmforge/squad/events.log"
[ -f "$LOG" ] || fail "events.log missing"
[ "$(grep -c ' a1 ' "$LOG")" -eq 3 ] || { cat "$LOG"; fail "a1 should log 3 events (created/result/accepted)"; }
ok "a1 logged created/result/accepted"
[ "$(grep -c ' a2 ' "$LOG")" -eq 4 ] || { cat "$LOG"; fail "a2 should log 4 events (created/result/rejected/replaced)"; }
ok "a2 logged created/result/rejected/replaced"
[ -z "$(grep -Ev '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z ' "$LOG")" ] || { cat "$LOG"; fail "events.log lines must be timestamped"; }
ok "all events.log lines timestamped"
grep -q ' a2 rejected reason=missing unit tests' "$LOG" || { cat "$LOG"; fail "reject reason not logged"; }
ok "reject reason logged"

step "squad: result retries cleanly after a crash-interrupted result"
# Simulate a prior `result` that copied the handoff but crashed before the
# status write: the file exists, the state still allows result. The retry
# must succeed — durable file state exists precisely so operations can be
# retried after a crash, and a raw stack trace is not an agent-legible error.
"$SCRIPTS/squad_assign.sh" create a4 implementer instructions.md > /dev/null
cp worker.handoff .swarmforge/squad/assignments/a4/result.handoff
set +e
OUT="$("$SCRIPTS/squad_assign.sh" result a4 worker.handoff 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 0 ] || { echo "$OUT"; fail "result retry after crashed copy should succeed, got $STATUS"; }
expect "result retry transition" "ASSIGNMENT_STATE: a4 created -> result" <<<"$OUT"
rm -f instructions.md worker.handoff

step "squad worker: allocate/activate/retire lifecycle"
OUT="$("$SCRIPTS/squad_worker.sh" allocate a1 implementer)"
expect "worker allocated" "WORKER_ALLOCATED: project-implementer-a1" <<<"$OUT"
[ -f .swarmforge/squad/workers/project-implementer-a1.edn ] || fail "worker record not written"
ok "worker record written"
OUT="$("$SCRIPTS/squad_worker.sh" activate project-implementer-a1)"
expect "worker activated" "WORKER_STATE: project-implementer-a1 allocated -> active" <<<"$OUT"
OUT="$("$SCRIPTS/squad_worker.sh" retire project-implementer-a1 assignment merged)"
expect "worker retired" "WORKER_STATE: project-implementer-a1 active -> retired" <<<"$OUT"

step "squad worker: list output and --active filter"
"$SCRIPTS/squad_worker.sh" allocate a2 implementer > /dev/null
"$SCRIPTS/squad_worker.sh" allocate a3 reviewer > /dev/null
"$SCRIPTS/squad_worker.sh" activate project-implementer-a2 > /dev/null
OUT="$("$SCRIPTS/squad_worker.sh" list)"
expect "list shows retired worker" "project-implementer-a1 retired implementer a1" <<<"$OUT"
expect "list shows active worker" "project-implementer-a2 active implementer a2" <<<"$OUT"
expect "list shows allocated worker" "project-reviewer-a3 allocated reviewer a3" <<<"$OUT"
expect "list reports active count and cap" "ACTIVE: 2/10" <<<"$OUT"
OUT="$("$SCRIPTS/squad_worker.sh" list --active)"
if grep -qF "project-implementer-a1" <<<"$OUT"; then fail "--active should hide retired workers"; fi
ok "--active hides retired workers"
expect "--active keeps allocated worker" "project-reviewer-a3 allocated reviewer a3" <<<"$OUT"

step "squad worker: capacity cap from squad.conf"
printf 'max_transient_agents 2\n' > swarmforge/squad.conf
set +e
OUT="$("$SCRIPTS/squad_worker.sh" allocate a4 implementer 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "capacity exhaustion should exit 2, got $STATUS"
expect "capacity token" "CAPACITY_EXHAUSTED" <<<"$OUT"
OUT="$("$SCRIPTS/squad_worker.sh" list)"
expect "list reflects lowered cap" "ACTIVE: 2/2" <<<"$OUT"
OUT="$("$SCRIPTS/squad_worker.sh" retire project-reviewer-a3)"
expect "retire straight from allocated" "WORKER_STATE: project-reviewer-a3 allocated -> retired" <<<"$OUT"
OUT="$("$SCRIPTS/squad_worker.sh" allocate a4 implementer)"
expect "retired worker frees a capacity slot" "WORKER_ALLOCATED: project-implementer-a4" <<<"$OUT"
rm swarmforge/squad.conf

step "squad worker: name sanitization and left-trim"
OUT="$("$SCRIPTS/squad_worker.sh" allocate a4 'Q.A')"
expect "uppercase and dots sanitized" "WORKER_ALLOCATED: project-q-a-a4" <<<"$OUT"
OUT="$("$SCRIPTS/squad_worker.sh" allocate 12345678901234567890123456789012 implementer)"
expect "long name left-trimmed and letter-prefixed" "WORKER_ALLOCATED: w2345678901234567890123456789012" <<<"$OUT"

step "squad worker: duplicate allocate, illegal transition, unknown worker"
set +e
OUT="$("$SCRIPTS/squad_worker.sh" allocate a4 'Q.A' 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "duplicate allocate should exit 2, got $STATUS"
expect "duplicate allocate token" "WORKER_EXISTS: project-q-a-a4" <<<"$OUT"
set +e
OUT="$("$SCRIPTS/squad_worker.sh" activate project-implementer-a1 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "activating a retired worker should exit 2, got $STATUS"
expect "worker illegal transition token" "INVALID_TRANSITION: worker 'project-implementer-a1' cannot go retired -> active" <<<"$OUT"
set +e
OUT="$("$SCRIPTS/squad_worker.sh" activate no-such 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 1 ] || fail "unknown worker should exit 1, got $STATUS"
expect "unknown worker token" "NO_SUCH_WORKER: no-such" <<<"$OUT"

step "squad assign: spawn transition"
OUT="$("$SCRIPTS/squad_assign.sh" spawn a3)"
expect "spawn transition" "ASSIGNMENT_STATE: a3 created -> spawned" <<<"$OUT"

step "squad worker: events.log records worker state changes"
grep -q ' project-implementer-a1 allocated template=implementer assignment=a1' "$LOG" || { cat "$LOG"; fail "allocate not logged"; }
ok "allocate logged"
grep -q ' project-implementer-a1 active' "$LOG" || { cat "$LOG"; fail "activate not logged"; }
ok "activate logged"
grep -q ' project-implementer-a1 retired reason=assignment merged' "$LOG" || { cat "$LOG"; fail "retire reason not logged"; }
ok "retire reason logged"
grep -q ' a3 spawned' "$LOG" || { cat "$LOG"; fail "spawn not logged"; }
ok "spawn logged"
[ "$(grep -c ' project-implementer-a1 ' "$LOG")" -eq 3 ] || { cat "$LOG"; fail "worker should log exactly 3 events"; }
ok "one line per worker state change"
[ -z "$(grep -Ev '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z ' "$LOG")" ] || { cat "$LOG"; fail "events.log lines must be timestamped"; }
ok "worker events.log lines timestamped"

step "approval: request/status/approve/reject lifecycle"
OUT="$("$SCRIPTS/squad_approval.sh" request ap1 merge a1 "Merge a1" ready for main)"
expect "approval requested" "APPROVAL_REQUESTED: ap1" <<<"$OUT"
AP=.swarmforge/squad/approvals/ap1.edn
[ -f "$AP" ] || fail "approval record not written"
grep -q ':state :pending' "$AP" || fail "approval should start pending"
ok "approval record starts pending"
OUT="$("$SCRIPTS/squad_approval.sh" status ap1)"
expect "status reports pending" "STATE: pending" <<<"$OUT"
expect "status carries gate" "GATE: merge" <<<"$OUT"
expect "status carries target" "TARGET: a1" <<<"$OUT"
expect "status carries title" "TITLE: Merge a1" <<<"$OUT"
expect "status carries reason" "REASON: ready for main" <<<"$OUT"
OUT="$("$SCRIPTS/squad_approval.sh" approve ap1 looks good)"
expect "approve transition" "APPROVAL_STATE: ap1 pending -> approved" <<<"$OUT"
OUT="$("$SCRIPTS/squad_approval.sh" status ap1)"
expect "status reports approved" "STATE: approved" <<<"$OUT"
expect "status carries decision detail" "DETAIL: looks good" <<<"$OUT"
grep -q ':decided-at' "$AP" || fail "approve should stamp :decided-at"
ok "approve stamps :decided-at"
"$SCRIPTS/squad_approval.sh" request ap2 merge a3 "Merge a3" ready > /dev/null
OUT="$("$SCRIPTS/squad_approval.sh" reject ap2 not safe yet)"
expect "reject transition" "APPROVAL_STATE: ap2 pending -> rejected" <<<"$OUT"
OUT="$("$SCRIPTS/squad_approval.sh" status ap2)"
expect "status reports rejected" "STATE: rejected" <<<"$OUT"
expect "status carries reject reason" "DETAIL: not safe yet" <<<"$OUT"

step "approval: decided approvals refuse further transitions"
set +e
OUT="$("$SCRIPTS/squad_approval.sh" approve ap2 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "approving a rejected approval should exit 2, got $STATUS"
expect "approval illegal transition" "INVALID_TRANSITION: approval 'ap2' cannot go rejected -> approved" <<<"$OUT"
set +e
OUT="$("$SCRIPTS/squad_approval.sh" reject ap1 changed my mind 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "rejecting an approved approval should exit 2, got $STATUS"
expect "approved cannot be rejected" "INVALID_TRANSITION" <<<"$OUT"

step "approval: duplicate, hostile id, unknown id"
set +e
OUT="$("$SCRIPTS/squad_approval.sh" request ap1 merge a1 "Again" again 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "duplicate approval should exit 2, got $STATUS"
expect "duplicate approval token" "APPROVAL_EXISTS: ap1" <<<"$OUT"
set +e
OUT="$("$SCRIPTS/squad_approval.sh" request '../evil' merge a1 "Evil" evil 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "hostile approval id should exit 2, got $STATUS"
expect "hostile approval id rejected before path resolution" "INVALID_APPROVAL_ID" <<<"$OUT"
set +e
OUT="$("$SCRIPTS/squad_approval.sh" status ghost 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 1 ] || fail "unknown approval should exit 1, got $STATUS"
expect "unknown approval token" "NO_SUCH_APPROVAL: ghost" <<<"$OUT"

step "approval: list puts pending approvals first"
"$SCRIPTS/squad_approval.sh" request ap0 merge a4 "Merge a4" pending one > /dev/null
OUT="$("$SCRIPTS/squad_approval.sh" list)"
expect "list shows pending approval" "ap0 pending merge a4 Merge a4" <<<"$OUT"
expect "list shows approved approval" "ap1 approved merge a1 Merge a1" <<<"$OUT"
expect "list shows rejected approval" "ap2 rejected merge a3 Merge a3" <<<"$OUT"
[ "$(head -n1 <<<"$OUT")" = "ap0 pending merge a4 Merge a4" ] \
  || { echo "$OUT"; fail "pending approval should list first"; }
ok "pending approvals list first"

step "approval: events.log records approval changes"
grep -q ' ap1 requested gate=merge target=a1' "$LOG" || { cat "$LOG"; fail "request not logged"; }
grep -q ' ap1 approved detail=looks good' "$LOG" || { cat "$LOG"; fail "approve not logged"; }
grep -q ' ap2 rejected reason=not safe yet' "$LOG" || { cat "$LOG"; fail "reject not logged"; }
ok "approval request/approve/reject logged"

step "theme: create/attach/status"
echo "Cleanup theme." > theme.md
OUT="$("$SCRIPTS/squad_theme.sh" create th1 theme.md)"
expect "theme created" "THEME_CREATED: th1" <<<"$OUT"
[ -f .swarmforge/squad/themes/th1/theme.md ] || fail "theme.md not copied"
[ -f .swarmforge/squad/themes/th1/status.edn ] || fail "theme status.edn not written"
ok "theme records written"
OUT="$("$SCRIPTS/squad_theme.sh" attach th1 a1)"
expect "assignment attached" "THEME_ATTACHED: th1 a1" <<<"$OUT"
"$SCRIPTS/squad_theme.sh" attach th1 a3 > /dev/null
OUT="$("$SCRIPTS/squad_theme.sh" status th1)"
expect "theme status names the theme" "THEME: th1" <<<"$OUT"
expect "attached a1 shows its current state" "a1 accepted" <<<"$OUT"
expect "attached a3 shows its current state" "a3 spawned" <<<"$OUT"

step "theme: error paths are agent-legible"
set +e
OUT="$("$SCRIPTS/squad_theme.sh" create th1 theme.md 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "duplicate theme should exit 2, got $STATUS"
expect "duplicate theme token" "THEME_EXISTS: th1" <<<"$OUT"
set +e
OUT="$("$SCRIPTS/squad_theme.sh" create '../evil' theme.md 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "hostile theme id should exit 2, got $STATUS"
expect "hostile theme id rejected before path resolution" "INVALID_THEME_ID" <<<"$OUT"
set +e
OUT="$("$SCRIPTS/squad_theme.sh" attach ghost a1 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "attach to a missing theme should exit 2, got $STATUS"
expect "missing theme token" "NO_SUCH_THEME: ghost" <<<"$OUT"
set +e
OUT="$("$SCRIPTS/squad_theme.sh" attach th1 ghost 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "attach of a missing assignment should exit 2, got $STATUS"
expect "missing assignment token" "NO_SUCH_ASSIGNMENT: ghost" <<<"$OUT"
set +e
OUT="$("$SCRIPTS/squad_theme.sh" attach th1 a1 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "re-attach should exit 2, got $STATUS"
expect "re-attach token" "ALREADY_ATTACHED: th1 a1" <<<"$OUT"

step "theme: events.log records theme changes"
grep -q ' th1 theme-created' "$LOG" || { cat "$LOG"; fail "theme create not logged"; }
grep -q ' th1 theme-attached assignment=a1' "$LOG" || { cat "$LOG"; fail "attach not logged"; }
ok "theme create/attach logged"
rm -f theme.md

step "squad: spawn driver file-state path (--no-agent)"
cd "$CODER"
SWARM="$TOOL_ROOT/bin/swarm"
echo "Do the thing precisely." > sp.md
"$SCRIPTS/squad_assign.sh" create sp1 implementer sp.md >/dev/null
OUT="$("$SWARM" squad spawn sp1 implementer --no-agent)"
expect "spawn reports worker" "WORKER_SPAWNED:" <<<"$OUT"
WORKER="$(grep -oE 'WORKER_SPAWNED: .*' <<<"$OUT" | cut -d' ' -f2)"
[ -d ".worktrees/$WORKER/.swarmforge/handoffs/inbox/new" ] || fail "worker worktree/queue not prepared"
ok "worker worktree and queue dirs created"
grep -q "^$WORKER	" .swarmforge/roles.tsv || fail "worker not registered in roles.tsv"
ok "worker registered for routing"
OUT="$("$SCRIPTS/squad_assign.sh" status sp1)"
expect "assignment moved to spawned" "STATE: spawned" <<<"$OUT"
set +e
OUT="$("$SWARM" squad spawn sp1 implementer --no-agent 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 1 ] || fail "re-spawn of spawned assignment should fail, got $STATUS"
expect "re-spawn rejected" "not 'created'" <<<"$OUT"

step "squad: worker contracts fall back to the template contract"
mkdir -p "$CODER/swarmforge/contracts"
cat > "$CODER/swarmforge/contracts/implementer.contract.edn" <<'EDN'
{:role "implementer"
 :artifact-roots ["src/"]
 :required-evidence [{:name "tests-green" :pattern "(?i)tests? passed"}]}
EDN
cd "$CODER/.worktrees/$WORKER"
echo w > forbidden2.txt && git add forbidden2.txt
git -c user.email=smoke@test -c user.name=smoke commit -qm "worker commit, no evidence"
WBAD="$(git rev-parse --short=10 HEAD)"
printf 'type: git_handoff\nto: coder\npriority: 50\ntask: wct\ncommit: %s\n' "$WBAD" > draft.txt
set +e
OUT="$(SWARMFORGE_ROLE="$WORKER" "$SCRIPTS/swarm_handoff.sh" draft.txt 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "worker contract violation should exit 2, got $STATUS"
expect "worker gated by template contract: paths" "outside role $WORKER's artifact roots" <<<"$OUT"
expect "worker gated by template contract: evidence" "required evidence 'tests-green'" <<<"$OUT"
rm -f draft.txt
cd "$CODER"
rm -rf "$CODER/swarmforge/contracts"

step "squad: retire frees routing and worktree"
OUT="$("$SWARM" squad retire "$WORKER" done --no-agent)"
expect "retire reports worker" "WORKER_RETIRED: $WORKER" <<<"$OUT"
grep -q "^$WORKER	" .swarmforge/roles.tsv && fail "worker still in roles.tsv"
ok "worker deregistered"
[ ! -d ".worktrees/$WORKER" ] || fail "worker worktree not removed"
ok "worker worktree removed"

step "spawn-request: create/list/drop lifecycle"
echo "Spawn me." > sr.md
"$SCRIPTS/squad_assign.sh" create sr1 implementer sr.md > /dev/null
OUT="$("$SCRIPTS/squad_spawn_request.sh" create sr1 implementer)"
expect "spawn-request created" "SPAWN_REQUEST_CREATED: sr1" <<<"$OUT"
REQ=.swarmforge/squad/spawn-requests/sr1.edn
[ -f "$REQ" ] || fail "spawn-request record not written"
grep -q ':assignment "sr1"' "$REQ" || fail "record missing :assignment"
grep -q ':template "implementer"' "$REQ" || fail "record missing :template"
grep -q ':requested-at' "$REQ" || fail "record missing :requested-at"
ok "record carries assignment/template/requested-at"
OUT="$("$SCRIPTS/squad_spawn_request.sh" list)"
expect "list shows the request" "sr1 implementer" <<<"$OUT"
OUT="$("$SCRIPTS/squad_spawn_request.sh" drop sr1)"
expect "spawn-request dropped" "SPAWN_REQUEST_DROPPED: sr1" <<<"$OUT"
[ ! -e "$REQ" ] || fail "dropped record still on disk"
ok "dropped record deleted"
grep -q ' sr1 spawn-requested template=implementer' "$LOG" || { cat "$LOG"; fail "create not logged"; }
grep -q ' sr1 spawn-request-dropped' "$LOG" || { cat "$LOG"; fail "drop not logged"; }
ok "spawn-request create/drop logged to events.log"

step "spawn-request: refusals are agent-legible"
"$SCRIPTS/squad_spawn_request.sh" create sr1 implementer > /dev/null
set +e
OUT="$("$SCRIPTS/squad_spawn_request.sh" create sr1 implementer 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "duplicate spawn-request should exit 2, got $STATUS"
expect "duplicate token" "SPAWN_REQUEST_EXISTS: sr1" <<<"$OUT"
set +e
OUT="$("$SCRIPTS/squad_spawn_request.sh" create ghost implementer 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "missing assignment should exit 2, got $STATUS"
expect "missing assignment token" "NO_SUCH_ASSIGNMENT: ghost" <<<"$OUT"
set +e
OUT="$("$SCRIPTS/squad_spawn_request.sh" create a1 implementer 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "non-created assignment should exit 2, got $STATUS"
expect "non-created token" "ASSIGNMENT_NOT_CREATED" <<<"$OUT"
set +e
OUT="$("$SCRIPTS/squad_spawn_request.sh" create '../evil' implementer 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "hostile id should exit 2, got $STATUS"
expect "hostile id rejected before path resolution" "INVALID_ASSIGNMENT_ID" <<<"$OUT"
set +e
OUT="$("$SCRIPTS/squad_spawn_request.sh" drop ghost 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 1 ] || fail "dropping a missing request should exit 1, got $STATUS"
expect "missing request token" "NO_SUCH_SPAWN_REQUEST: ghost" <<<"$OUT"
"$SCRIPTS/squad_spawn_request.sh" drop sr1 > /dev/null
rm -f sr.md

step "advisor: empty state is an empty report, exit 0"
ADVISOR="$WORK/advisor"
mkdir -p "$ADVISOR/.swarmforge" "$ADVISOR/swarmforge"
cp "$PROJECT/.swarmforge/roles.tsv" "$ADVISOR/.swarmforge/roles.tsv"
cp -r "$TOOL_ROOT/swarmforge/scripts" "$ADVISOR/swarmforge/scripts"
cd "$ADVISOR"
synth() { # synth <assignment-id> <status-edn>
  mkdir -p ".swarmforge/squad/assignments/$1"
  printf '%s\n' "$2" > ".swarmforge/squad/assignments/$1/status.edn"
}
put_worker() { # put_worker <name> <record-edn>
  mkdir -p .swarmforge/squad/workers
  printf '%s\n' "$2" > ".swarmforge/squad/workers/$1.edn"
}
set +e
OUT="$("$SCRIPTS/squad_next.sh")"
STATUS=$?
set -e
[ "$STATUS" -eq 0 ] || fail "advisor should exit 0 on empty state, got $STATUS"
[ -z "$OUT" ] || { echo "$OUT"; fail "empty state should print nothing"; }
ok "empty report exits 0 and prints nothing"

step "advisor: rows 10, 1, 2 (spawn-request vs capacity)"
synth c1 '{:id "c1" :template "implementer" :state :created}'
OUT="$("$SCRIPTS/squad_next.sh")"
expect "row 10: created without spawn-request" "NEXT_ACTION: needs-spawn-request" <<<"$OUT"
expect "row 10 targets the assignment" "TARGET: c1" <<<"$OUT"
expect "row 10 is residual" "CLASS: residual" <<<"$OUT"
"$SCRIPTS/squad_spawn_request.sh" create c1 implementer > /dev/null
OUT="$("$SCRIPTS/squad_next.sh")"
expect "row 1: spawn when capacity available" "NEXT_ACTION: spawn" <<<"$OUT"
expect "row 1 is mechanical" "CLASS: mechanical" <<<"$OUT"
if grep -q 'needs-spawn-request' <<<"$OUT"; then fail "requested assignment must not re-nag row 10"; fi
ok "spawn-request suppresses needs-spawn-request"
printf 'max_transient_agents 0\n' > swarmforge/squad.conf
OUT="$("$SCRIPTS/squad_next.sh")"
expect "row 2: wait-capacity when exhausted" "NEXT_ACTION: wait-capacity" <<<"$OUT"
if grep -q '^NEXT_ACTION: spawn$' <<<"$OUT"; then fail "no spawn should be advised at zero capacity"; fi
ok "zero capacity advises no spawn"
rm swarmforge/squad.conf

step "advisor: full synthetic state fires every remaining row, in table order"
synth c2 '{:id "c2" :template "implementer" :state :created}'
"$SCRIPTS/squad_spawn_request.sh" create c2 implementer > /dev/null
synth c2 '{:id "c2" :template "implementer" :state :spawned}'
synth c3 '{:id "c3" :template "implementer" :state :result}'
synth c4 '{:id "c4" :template "implementer" :state :accepted}'
synth c5 '{:id "c5" :template "implementer" :state :merged}'
put_worker w-c5 '{:name "w-c5" :template "implementer" :assignment "c5" :state :active}'
synth c6 '{:id "c6" :template "implementer" :state :rejected}'
put_worker w-c6 '{:name "w-c6" :template "implementer" :assignment "c6" :state :allocated}'
synth c7 '{:id "c7" :template "implementer" :state :merge-blocked}'
synth c8 '{:id "c8" :template "implementer" :state :merge-blocked :replaced-by "m1"}'
synth m1 '{:id "m1" :template "merger" :state :merge-blocked :replaces "c8" :replaced-by "m2"}'
synth m2 '{:id "m2" :template "merger" :state :merge-blocked :replaces "m1"}'
synth c9 '{:id "c9" :template "implementer" :state :merge-blocked :replaced-by "m3"}'
synth m3 '{:id "m3" :template "merger" :state :merge-blocked :replaces "c9"}'
synth c10 '{:id "c10" :template "implementer" :state :created}'
OUT="$("$SCRIPTS/squad_next.sh")"
SEQ="$(grep '^NEXT_ACTION: ' <<<"$OUT" | sed 's/^NEXT_ACTION: //' | tr '\n' ' ')"
WANT="spawn drop-stale-spawn-request review merge retire-worker retire-worker route-merger route-merger escalate-to-user needs-spawn-request "
[ "$SEQ" = "$WANT" ] || { echo "$OUT"; fail "action sequence should follow table order; got: $SEQ"; }
ok "all rows fire in table order"
block_of() { grep -A3 "^NEXT_ACTION: $1\$" <<<"$OUT"; }
block_of drop-stale-spawn-request | grep -q 'TARGET: c2' || fail "row 3 should target the stale request c2"
ok "row 3: stale spawn-request targeted"
block_of review | grep -q 'TARGET: c3' || fail "row 4 should target c3"
ok "row 4: result assignment offered for review"
block_of merge | grep -q 'TARGET: c4' || fail "row 5 should target c4"
ok "row 5: accepted assignment offered for merge"
block_of retire-worker | grep -q 'TARGET: w-c5' || fail "row 6 should target worker w-c5"
block_of retire-worker | grep -q 'TARGET: w-c6' || fail "row 7 should target worker w-c6"
ok "rows 6-7: retire-worker targets worker names"
block_of route-merger | grep -q 'TARGET: c7' || fail "row 8 should target c7 (depth 0)"
block_of route-merger | grep -q 'TARGET: m3' || fail "row 8 should target m3 (depth 1)"
ok "row 8: route-merger under the depth cap"
block_of escalate-to-user | grep -q 'TARGET: m2' || fail "row 9 should target m2 (depth 2)"
ok "row 9: escalate at the depth cap"
block_of needs-spawn-request | grep -q 'TARGET: c10' || fail "row 10 should target c10"
ok "row 10: created without request reminded"
for hidden in c8 m1 c9; do
  if grep -q "^TARGET: $hidden\$" <<<"$OUT"; then fail "replaced assignment $hidden should stay silent"; fi
done
ok "replaced assignments trigger no judgment rows"
[ "$(grep -c '^NEXT_ACTION: ' <<<"$OUT")" -eq 10 ] || fail "expected 10 blocks"
[ "$(grep -c '^CLASS: ' <<<"$OUT")" -eq 10 ] || fail "every block needs a CLASS line"
[ "$(grep -c '^TARGET: ' <<<"$OUT")" -eq 10 ] || fail "every block needs a TARGET line"
[ "$(grep -c '^REASON: ' <<<"$OUT")" -eq 10 ] || fail "every block needs a REASON line"
[ "$(grep -c '^$' <<<"$OUT")" -eq 9 ] || { echo "$OUT"; fail "10 blocks need exactly 9 blank separators"; }
ok "blocks are 4 lines separated by single blank lines"

step "advisor: max_merger_depth read from squad.conf"
printf 'max_merger_depth 1\n' > swarmforge/squad.conf
OUT="$("$SCRIPTS/squad_next.sh")"
[ "$(grep -c '^NEXT_ACTION: escalate-to-user$' <<<"$OUT")" -eq 2 ] || { echo "$OUT"; fail "depth cap 1 should escalate both m3 and m2"; }
[ "$(grep -c '^NEXT_ACTION: route-merger$' <<<"$OUT")" -eq 1 ] || { echo "$OUT"; fail "depth cap 1 should still route c7 (depth 0)"; }
ok "lowered depth cap moves depth-1 merger to escalate"
rm swarmforge/squad.conf

step "advisor: class filters"
OUT="$("$SCRIPTS/squad_next.sh" --mechanical-only)"
if grep -q '^CLASS: residual$' <<<"$OUT"; then fail "--mechanical-only leaked a residual block"; fi
expect "--mechanical-only keeps mechanical blocks" "CLASS: mechanical" <<<"$OUT"
OUT="$("$SCRIPTS/squad_next.sh" --residual-only)"
if grep -q '^CLASS: mechanical$' <<<"$OUT"; then fail "--residual-only leaked a mechanical block"; fi
expect "--residual-only keeps residual blocks" "CLASS: residual" <<<"$OUT"

step "advisor: read-only and deterministic"
BEFORE="$(find .swarmforge swarmforge -type f -print0 | sort -z | xargs -0 md5sum)"
FIRST="$("$SCRIPTS/squad_next.sh")"
SECOND="$("$SCRIPTS/squad_next.sh")"
"$SCRIPTS/squad_next.sh" --residual-only > /dev/null
AFTER="$(find .swarmforge swarmforge -type f -print0 | sort -z | xargs -0 md5sum)"
[ "$BEFORE" = "$AFTER" ] || fail "advisor mutated file state"
ok "state identical before and after advisor runs"
[ "$FIRST" = "$SECOND" ] || fail "advisor output should be deterministic"
ok "back-to-back runs are identical"

step "advisor: partial capacity splits spawn/wait in request order"
# One free slot, two pending requests: the budget must hand out exactly the
# remaining capacity, not evaluate each request against a >0 check.
ADVISOR2="$WORK/advisor2"
mkdir -p "$ADVISOR2/.swarmforge" "$ADVISOR2/swarmforge"
cp "$PROJECT/.swarmforge/roles.tsv" "$ADVISOR2/.swarmforge/roles.tsv"
cp -r "$TOOL_ROOT/swarmforge/scripts" "$ADVISOR2/swarmforge/scripts"
cd "$ADVISOR2"
echo "work" > pc.md
printf 'max_transient_agents 1\n' > swarmforge/squad.conf
"$SCRIPTS/squad_assign.sh" create pc1 implementer pc.md > /dev/null
"$SCRIPTS/squad_assign.sh" create pc2 implementer pc.md > /dev/null
"$SCRIPTS/squad_spawn_request.sh" create pc1 implementer > /dev/null
"$SCRIPTS/squad_spawn_request.sh" create pc2 implementer > /dev/null
OUT="$("$SCRIPTS/squad_next.sh" --mechanical-only)"
grep -A3 '^NEXT_ACTION: spawn$' <<<"$OUT" | grep -q 'TARGET: pc1' \
  || { echo "$OUT"; fail "one free slot should spawn the first request"; }
grep -A3 '^NEXT_ACTION: wait-capacity$' <<<"$OUT" | grep -q 'TARGET: pc2' \
  || { echo "$OUT"; fail "overflow request should wait-capacity"; }
[ "$(grep -c '^NEXT_ACTION: spawn$' <<<"$OUT")" -eq 1 ] \
  || { echo "$OUT"; fail "exactly one spawn should be advised for one free slot"; }
ok "one slot, two requests: first spawns, second waits"

step "spawn-request: a replaced (retired) assignment is refused"
# squad_assign replace! keeps the old record's state, so a replaced
# :created assignment would otherwise pass the :created gate and the
# request would be born stale (reviewer finding, squad-advisor).
"$SCRIPTS/squad_assign.sh" create fr1 implementer pc.md > /dev/null
"$SCRIPTS/squad_assign.sh" replace fr1 fr2 implementer pc.md > /dev/null
set +e
OUT="$("$SCRIPTS/squad_spawn_request.sh" create fr1 implementer 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] \
  || { echo "$OUT"; fail "spawn-request for a replaced assignment should be refused (exit 2), got $STATUS"; }
expect "replaced assignment token" "ASSIGNMENT_REPLACED: 'fr1' was replaced by fr2" <<<"$OUT"

step "spawn-request: hostile template cannot forge events.log lines"
# The template becomes log-event! detail and, in slice B, daemon spawn
# arguments; its shape is gated like assignment ids (reviewer finding,
# squad-advisor).
"$SCRIPTS/squad_assign.sh" create fr3 implementer pc.md > /dev/null
set +e
OUT="$("$SCRIPTS/squad_spawn_request.sh" create fr3 \
  "$(printf 'implementer\n2026-01-01T00:00:00Z fr3 accepted FORGED')" 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || { echo "$OUT"; fail "hostile template should exit 2, got $STATUS"; }
expect "hostile template token" "INVALID_TEMPLATE" <<<"$OUT"
if grep -q 'FORGED' .swarmforge/squad/events.log; then
  fail "hostile template must not forge an events.log line"
fi
ok "template cannot forge audit-log lines"

step "events.log: newlines in free-text detail are folded to one line"
# Reject reasons stay free text, so log-event! itself must keep one event
# on one line even when the reason embeds a forged timestamped line.
"$SCRIPTS/squad_assign.sh" result fr3 pc.md > /dev/null
"$SCRIPTS/squad_assign.sh" reject fr3 \
  "$(printf 'bad work\n2026-01-01T00:00:00Z fr3 accepted FORGED2')" > /dev/null
grep -q 'FORGED2' .swarmforge/squad/events.log || fail "reject reason not logged"
if grep -q '^2026-01-01T00:00:00Z fr3 accepted FORGED2' .swarmforge/squad/events.log; then
  fail "newline in reject reason forged an events.log line"
fi
ok "free-text detail cannot forge audit-log lines"
cd "$CODER"

step "advisor: merge gate unset keeps row 5 byte-identical (S4 row 5*)"
S4ADV="$WORK/advisor-s4"
mkdir -p "$S4ADV/.swarmforge" "$S4ADV/swarmforge"
cp "$PROJECT/.swarmforge/roles.tsv" "$S4ADV/.swarmforge/roles.tsv"
cp -r "$TOOL_ROOT/swarmforge/scripts" "$S4ADV/swarmforge/scripts"
cd "$S4ADV"
synth g1 '{:id "g1" :template "implementer" :state :accepted}'
OUT="$("$SCRIPTS/squad_next.sh")"
expect "gate unset: accepted merges" "NEXT_ACTION: merge" <<<"$OUT"
expect "gate unset: reason unchanged" "REASON: accepted; daemon merges the result commit into main" <<<"$OUT"
if grep -q 'request-approval' <<<"$OUT"; then fail "no gate should mean no approval rows"; fi
ok "gate unset advises merge exactly as before"

step "advisor: gate set without a record advises request-approval, no merge (row 11)"
printf 'require_approval merge\n' > swarmforge/squad.conf
OUT="$("$SCRIPTS/squad_next.sh")"
expect "row 11 fires" "NEXT_ACTION: request-approval" <<<"$OUT"
expect "row 11 targets the assignment" "TARGET: g1" <<<"$OUT"
expect "row 11 is residual" "CLASS: residual" <<<"$OUT"
if grep -q '^NEXT_ACTION: merge$' <<<"$OUT"; then fail "unapproved accepted assignment must not merge"; fi
ok "merge withheld until an approval record exists"

step "advisor: pending approval advises await-user-approval (row 12)"
"$SCRIPTS/squad_approval.sh" request apg1 merge g1 "Merge g1" ready > /dev/null
OUT="$("$SCRIPTS/squad_next.sh")"
expect "row 12 fires" "NEXT_ACTION: await-user-approval" <<<"$OUT"
expect "row 12 targets the approval" "TARGET: apg1" <<<"$OUT"
expect "row 12 is residual" "CLASS: residual" <<<"$OUT"
if grep -q '^NEXT_ACTION: merge$' <<<"$OUT"; then fail "pending approval must not merge"; fi
if grep -q 'request-approval' <<<"$OUT"; then fail "existing approval record must silence row 11"; fi
ok "pending approval holds the merge and silences row 11"

step "advisor: approved record releases the merge (row 5*)"
"$SCRIPTS/squad_approval.sh" approve apg1 ship it > /dev/null
OUT="$("$SCRIPTS/squad_next.sh")"
expect "approved: merge advised" "NEXT_ACTION: merge" <<<"$OUT"
expect "approved: merge targets g1" "TARGET: g1" <<<"$OUT"
if grep -q 'await-user-approval\|request-approval' <<<"$OUT"; then
  fail "decided approval should end rows 11-12"
fi
ok "approved gate releases the merge"

step "advisor: rejected approval advises handle-approval-rejection (row 13)"
synth g2 '{:id "g2" :template "implementer" :state :accepted}'
"$SCRIPTS/squad_approval.sh" request apg2 merge g2 "Merge g2" ready > /dev/null
"$SCRIPTS/squad_approval.sh" reject apg2 not safe > /dev/null
OUT="$("$SCRIPTS/squad_next.sh")"
expect "row 13 fires" "NEXT_ACTION: handle-approval-rejection" <<<"$OUT"
grep -A3 '^NEXT_ACTION: handle-approval-rejection$' <<<"$OUT" | grep -q 'TARGET: g2' \
  || { echo "$OUT"; fail "row 13 should target the rejected approval's assignment"; }
ok "rejected approval routes the assignment back to the leader"
if grep -A3 '^NEXT_ACTION: merge$' <<<"$OUT" | grep -q 'TARGET: g2'; then
  fail "rejected approval must not merge g2"
fi
ok "rejected approval withholds g2's merge"
SEQ="$(grep '^NEXT_ACTION: ' <<<"$OUT" | sed 's/^NEXT_ACTION: //' | tr '\n' ' ')"
[ "$SEQ" = "merge handle-approval-rejection " ] \
  || { echo "$OUT"; fail "S4 rows should follow table order; got: $SEQ"; }
ok "S4 rows fire in table order"
rm swarmforge/squad.conf
cd "$CODER"

step "advisor: approved re-request supersedes a rejection (rows 5*/13)"
# rejected ap1 + later approved ap2 for the same target: row 5* releases
# the merge (mechanical, daemon-applied) while row 13 simultaneously tells
# the leader to reject/rework the same assignment — contradictory advice
# racing the daemon's merge. An :approved record superseding the rejection
# must silence row 13.
F4="$WORK/advisor-s4-findings"
mkdir -p "$F4/.swarmforge" "$F4/swarmforge"
cp "$PROJECT/.swarmforge/roles.tsv" "$F4/.swarmforge/roles.tsv"
cp -r "$TOOL_ROOT/swarmforge/scripts" "$F4/swarmforge/scripts"
cd "$F4"
synth f1 '{:id "f1" :template "implementer" :state :accepted}'
printf 'require_approval merge\n' > swarmforge/squad.conf
"$SCRIPTS/squad_approval.sh" request apf1 merge f1 "Merge f1" first ask > /dev/null
"$SCRIPTS/squad_approval.sh" reject apf1 not yet > /dev/null
"$SCRIPTS/squad_approval.sh" request apf2 merge f1 "Merge f1 again" second ask > /dev/null
"$SCRIPTS/squad_approval.sh" approve apf2 ok now > /dev/null
OUT="$("$SCRIPTS/squad_next.sh")"
expect "approved re-request releases the merge" "NEXT_ACTION: merge" <<<"$OUT"
if grep -A3 '^NEXT_ACTION: handle-approval-rejection$' <<<"$OUT" | grep -q 'TARGET: f1'; then
  echo "$OUT"
  fail "an approved record superseding the rejection must silence row 13 for f1"
fi
ok "superseded rejection does not contradict the released merge"
cd "$CODER"

step "theme: create recovers from a crash-interrupted create"
# A theme dir without status.edn (create interrupted between create-dirs
# and write-record!) is unrecoverable: create says THEME_EXISTS, while
# status/attach say NO_SUCH_THEME, and no tool can repair it. The
# assignments layer explicitly skips such half-created dirs; themes should
# extend the same grace — re-running create must succeed.
mkdir -p .swarmforge/squad/themes/thwedge
echo "wedge theme" > thwedge.md
set +e
OUT="$("$SCRIPTS/squad_theme.sh" create thwedge thwedge.md 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 0 ] || { echo "$OUT"; fail "create must recover a half-created theme dir, got exit $STATUS"; }
expect "create recovers a half-created theme" "THEME_CREATED: thwedge" <<<"$OUT"
OUT="$("$SCRIPTS/squad_theme.sh" status thwedge)"
expect "recovered theme has a readable status" "THEME: thwedge" <<<"$OUT"
rm -f thwedge.md

step "squadd: simulator project (leader row, scripted workers, no agents)"
SQ="$WORK/squadproj"
mkdir -p "$SQ"
git -C "$SQ" init -qb main
echo "base line" > "$SQ/sim.txt"
git -C "$SQ" add sim.txt
git -C "$SQ" -c user.email=smoke@test -c user.name=smoke commit -qm "initial"
mkdir -p "$SQ/.swarmforge" "$SQ/swarmforge"
printf 'squad-leader\tmaster\t%s\tsquad-leader\tsquad-leader\tclaude\ttask\n' "$SQ" \
  > "$SQ/.swarmforge/roles.tsv"
cp -r "$TOOL_ROOT/swarmforge/scripts" "$SQ/swarmforge/scripts"
cd "$SQ"
export SWARMFORGE_NO_AGENT=1
export SWARM_BIN="$TOOL_ROOT/bin/swarm"
echo "Do the work." > instr.md
play_worker() { # play_worker <worker> <assignment> <sim.txt content>
  # The scripted worker: commit a real change in the worker worktree and
  # hand it to the leader exactly as a live worker would.
  local wt=".worktrees/$1"
  echo "$3" > "$wt/sim.txt"
  git -C "$wt" add sim.txt
  git -C "$wt" -c user.email=smoke@test -c user.name=smoke commit -qm "work for $2"
  printf 'type: git_handoff\nto: squad-leader\npriority: 50\ntask: %s\ncommit: %s\n' \
    "$2" "$(git -C "$wt" rev-parse --short=10 HEAD)" > "$wt/draft.txt"
  (cd "$wt" && SWARMFORGE_ROLE="$1" swarmforge/scripts/swarm_handoff.sh draft.txt > /dev/null)
}
record_result() { # record_result <assignment> <worker>
  local file
  file="$(ls .swarmforge/handoffs/inbox/new/*_from_"$2"_*.handoff)"
  "$SCRIPTS/squad_assign.sh" result "$1" "$file" > /dev/null
}
[ -f swarmforge/scripts/squadd.bb ] || fail "squadd.bb missing"
ok "simulator project prepared"

step "squadd: spawn pass (assignment spawned, worker active, request consumed)"
"$SCRIPTS/squad_assign.sh" create d1 implementer instr.md > /dev/null
"$SCRIPTS/squad_spawn_request.sh" create d1 implementer > /dev/null
bb "$SCRIPTS/squadd.bb" "$SQ" --once
W1=squadproj-implementer-d1
OUT="$("$SCRIPTS/squad_assign.sh" status d1)"
expect "d1 spawned by daemon" "STATE: spawned" <<<"$OUT"
grep -q ':state :active' ".swarmforge/squad/workers/$W1.edn" || fail "worker $W1 not active"
ok "worker active"
[ ! -e .swarmforge/squad/spawn-requests/d1.edn ] || fail "spawn-request not consumed"
ok "spawn-request consumed"
grep -q "^$W1	" .swarmforge/roles.tsv || fail "worker not registered for routing"
ok "worker registered"
grep -q ' d1 squadd-spawn' .swarmforge/squad/events.log || fail "squadd-spawn not logged"
ok "squadd-spawn logged to events.log"

step "squadd: merge pass (accepted result lands on main)"
play_worker "$W1" d1 "d1 version"
bb "$SCRIPTS/handoffd.bb" "$SQ" --once
record_result d1 "$W1"
"$SCRIPTS/squad_assign.sh" accept d1 > /dev/null
C1="$(git -C ".worktrees/$W1" rev-parse HEAD)"
bb "$SCRIPTS/squadd.bb" "$SQ" --once
OUT="$("$SCRIPTS/squad_assign.sh" status d1)"
expect "d1 merged" "STATE: merged" <<<"$OUT"
git merge-base --is-ancestor "$C1" HEAD || fail "worker commit not reachable from main"
ok "worker commit reachable from main"
[ "$(cat sim.txt)" = "d1 version" ] || fail "worker change not visible on main"
ok "worker change visible on main"
grep -q ' d1 squadd-merge' .swarmforge/squad/events.log || fail "squadd-merge not logged"
ok "squadd-merge logged"

step "squadd: retire pass (merged assignment's worker retired)"
bb "$SCRIPTS/squadd.bb" "$SQ" --once
grep -q ':state :retired' ".swarmforge/squad/workers/$W1.edn" || fail "worker not retired"
ok "worker record retired"
if grep -q "^$W1	" .swarmforge/roles.tsv; then fail "worker still registered"; fi
ok "worker deregistered"
[ ! -d ".worktrees/$W1" ] || fail "worker worktree not removed"
ok "worker worktree removed"
grep -q " $W1 squadd-retire-worker" .swarmforge/squad/events.log || fail "retire not logged"
ok "squadd-retire-worker logged"

step "squadd: merged state rejects further transitions"
set +e
OUT="$("$SCRIPTS/squad_assign.sh" merge d1 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 2 ] || fail "re-merge should exit 2, got $STATUS"
expect "merge illegal transition" "INVALID_TRANSITION" <<<"$OUT"

step "squadd: conflict path (first merges, second goes merge-blocked)"
"$SCRIPTS/squad_assign.sh" create d2 implementer instr.md > /dev/null
"$SCRIPTS/squad_assign.sh" create d3 implementer instr.md > /dev/null
"$SCRIPTS/squad_spawn_request.sh" create d2 implementer > /dev/null
"$SCRIPTS/squad_spawn_request.sh" create d3 implementer > /dev/null
bb "$SCRIPTS/squadd.bb" "$SQ" --once
W2=squadproj-implementer-d2
W3=squadproj-implementer-d3
{ [ -d ".worktrees/$W2" ] && [ -d ".worktrees/$W3" ]; } || fail "both workers should spawn in one pass"
ok "both workers spawned in one pass"
play_worker "$W2" d2 "d2 version"
play_worker "$W3" d3 "d3 version"
bb "$SCRIPTS/handoffd.bb" "$SQ" --once
record_result d2 "$W2"
record_result d3 "$W3"
"$SCRIPTS/squad_assign.sh" accept d2 > /dev/null
"$SCRIPTS/squad_assign.sh" accept d3 > /dev/null
bb "$SCRIPTS/squadd.bb" "$SQ" --once
OUT="$("$SCRIPTS/squad_assign.sh" status d2)"
expect "d2 merged" "STATE: merged" <<<"$OUT"
[ "$(cat sim.txt)" = "d2 version" ] || fail "d2's commit should win on main"
ok "d2 on main"
OUT="$("$SCRIPTS/squad_assign.sh" status d3)"
expect "d3 merge-blocked" "STATE: merge-blocked" <<<"$OUT"
expect "d3 carries conflict detail" "REASON:" <<<"$OUT"
[ ! -e .git/MERGE_HEAD ] || fail "conflicted merge not aborted"
ok "conflicted merge aborted cleanly"
grep -q ' d3 squadd-merge-blocked' .swarmforge/squad/events.log || fail "merge-blocked not logged"
ok "squadd-merge-blocked logged"
OUT="$("$SCRIPTS/squad_next.sh" --residual-only)"
grep -A3 '^NEXT_ACTION: route-merger$' <<<"$OUT" | grep -q 'TARGET: d3' \
  || { echo "$OUT"; fail "advisor should route a merger for d3"; }
ok "advisor emits route-merger for d3"
grep -q 'residual-new' .swarmforge/squad/daemon/squadd.log || fail "new residual not logged"
ok "daemon noticed the new residual"

step "squadd: merge-blocked assignment is replaceable (merger routing)"
OUT="$("$SCRIPTS/squad_assign.sh" replace d3 d3m merger instr.md)"
expect "merge-blocked replaced" "ASSIGNMENT_REPLACED: d3 -> d3m" <<<"$OUT"

step "squadd: stale request dropped, merged worker retired, same pass"
"$SCRIPTS/squad_assign.sh" create d4 implementer instr.md > /dev/null
"$SCRIPTS/squad_spawn_request.sh" create d4 implementer > /dev/null
"$SCRIPTS/squad_assign.sh" result d4 instr.md > /dev/null
bb "$SCRIPTS/squadd.bb" "$SQ" --once
[ ! -e .swarmforge/squad/spawn-requests/d4.edn ] || fail "stale request should be dropped"
ok "stale request dropped"
grep -q ' d4 squadd-drop-stale-spawn-request' .swarmforge/squad/events.log || fail "stale drop not logged"
ok "stale drop logged"
grep -q ':state :retired' ".swarmforge/squad/workers/$W2.edn" || fail "d2's worker should retire"
ok "merged assignment's worker retired"

step "squadd: spawn failure leaves the request for retry"
"$SCRIPTS/squad_assign.sh" create d5 implementer instr.md > /dev/null
"$SCRIPTS/squad_spawn_request.sh" create d5 implementer > /dev/null
SWARM_BIN=/bin/false bb "$SCRIPTS/squadd.bb" "$SQ" --once
[ -e .swarmforge/squad/spawn-requests/d5.edn ] || fail "failed spawn must leave the request"
ok "request survives failed spawn"
OUT="$("$SCRIPTS/squad_assign.sh" status d5)"
expect "d5 still created" "STATE: created" <<<"$OUT"
grep -q 'spawn-failed d5' .swarmforge/squad/daemon/squadd.log || fail "spawn failure not logged"
ok "spawn failure logged"
bb "$SCRIPTS/squadd.bb" "$SQ" --once
OUT="$("$SCRIPTS/squad_assign.sh" status d5)"
expect "d5 spawned on retry" "STATE: spawned" <<<"$OUT"
[ ! -e .swarmforge/squad/spawn-requests/d5.edn ] || fail "request should be consumed on retry"
ok "retry consumed the request"
unset SWARMFORGE_NO_AGENT SWARM_BIN
cd "$CODER"

step "squadd: a residual wakes the configured leader agent"
# The main suite exports SWARMFORGE_WAKE_CMD=none, so the wake path
# (roles.tsv agent lookup + wake shell-out) was otherwise never exercised.
FP="$WORK/findproj"
mkdir -p "$FP"
git -C "$FP" init -qb main
echo base > "$FP/f.txt"
git -C "$FP" add f.txt
git -C "$FP" -c user.email=smoke@test -c user.name=smoke commit -qm initial
mkdir -p "$FP/.swarmforge" "$FP/swarmforge"
printf 'squad-leader\tmaster\t%s\tsquad-leader\tsquad-leader\tclaude\ttask\n' "$FP" \
  > "$FP/.swarmforge/roles.tsv"
cp -r "$TOOL_ROOT/swarmforge/scripts" "$FP/swarmforge/scripts"
cd "$FP"
echo work > instr.md
cat > fake-wake <<'EOF'
#!/usr/bin/env bash
echo "WAKE $*" >> "$(dirname "$0")/wakes.log"
EOF
chmod +x fake-wake
WAKE_BIN="$FP/fake-wake"
if command -v cygpath >/dev/null 2>&1; then
  printf '@echo WAKE %%* >> "%%~dp0wakes.log"\r\n' > fake-wake.bat
  WAKE_BIN="$(cygpath -m "$FP")/fake-wake.bat"
fi
"$SCRIPTS/squad_assign.sh" create wk0 implementer instr.md > /dev/null
SWARMFORGE_WAKE_CMD="$WAKE_BIN" bb "$SCRIPTS/squadd.bb" "$FP" --once
grep -q '^WAKE agent prompt squad-leader ' wakes.log \
  || { cat wakes.log 2>/dev/null; fail "wake should reach the leader agent from roles.tsv"; }
ok "wake command carries the leader agent name"

step "squadd: merge only happens on the main branch"
# With a side branch checked out, the daemon must skip the merge (and
# retry next poll) instead of marking :merged while main never receives
# the commit (reviewer finding, squadd).
git checkout -qb work main
echo feature > feature.txt
git add feature.txt
git -c user.email=smoke@test -c user.name=smoke commit -qm "worker change"
WC="$(git rev-parse --short=10 HEAD)"
git checkout -q main
"$SCRIPTS/squad_assign.sh" create wb1 implementer instr.md > /dev/null
printf 'type: git_handoff\nfrom: worker\ncommit: %s\n' "$WC" > wb1.handoff
"$SCRIPTS/squad_assign.sh" result wb1 wb1.handoff > /dev/null
"$SCRIPTS/squad_assign.sh" accept wb1 > /dev/null
git checkout -qb side main
bb "$SCRIPTS/squadd.bb" "$FP" --once
if "$SCRIPTS/squad_assign.sh" status wb1 | grep -q 'STATE: merged'; then
  git merge-base --is-ancestor "$WC" main \
    || fail "assignment marked merged but its commit is not on main"
fi
ok "merged implies the commit landed on main"
OUT="$("$SCRIPTS/squad_assign.sh" status wb1)"
expect "off-main merge skipped, not blocked" "STATE: accepted" <<<"$OUT"
grep -q 'merge-skipped wb1' .swarmforge/squad/daemon/squadd.log \
  || fail "skipped merge should be logged"
ok "skip logged for retry"
git checkout -q main
bb "$SCRIPTS/squadd.bb" "$FP" --once
OUT="$("$SCRIPTS/squad_assign.sh" status wb1)"
expect "merge retried once back on main" "STATE: merged" <<<"$OUT"
git merge-base --is-ancestor "$WC" main || fail "retried merge should land on main"
ok "retried merge landed on main"

step "squadd: residual action change on a known target re-wakes the leader"
# The wake dedup is keyed on [target action] pairs: a target that moves
# review -> (accept, conflict) -> route-merger between polls of the
# long-running daemon must wake the leader again (reviewer finding,
# squadd). --once runs cannot see this: each is a fresh process with an
# empty known-residuals.
git checkout -qb xwork main
echo "worker version" > f.txt
git -c user.email=smoke@test -c user.name=smoke commit -qam "x work"
XC="$(git rev-parse --short=10 HEAD)"
git checkout -q main
echo "main moved on" > f.txt
git -c user.email=smoke@test -c user.name=smoke commit -qam "conflicting main change"
"$SCRIPTS/squad_assign.sh" create fx1 implementer instr.md > /dev/null
printf 'type: git_handoff\nfrom: worker\ncommit: %s\n' "$XC" > fx1.handoff
"$SCRIPTS/squad_assign.sh" result fx1 fx1.handoff > /dev/null
rm -f wakes.log
SWARMFORGE_WAKE_CMD="$WAKE_BIN" bb "$SCRIPTS/squadd.bb" "$FP" > /dev/null 2>&1 &
SQDPID=$!
sleep 3
[ "$(grep -c '^WAKE ' wakes.log 2>/dev/null)" -eq 1 ] \
  || fail "probe setup: expected exactly one wake for the review residual"
"$SCRIPTS/squad_assign.sh" accept fx1 > /dev/null
sleep 4
mkdir -p .swarmforge/squad/daemon
touch .swarmforge/squad/daemon/stop
wait "$SQDPID" 2>/dev/null || true
"$SCRIPTS/squad_next.sh" --residual-only | grep -q 'route-merger' \
  || fail "probe setup: route-merger residual expected after the conflict"
[ "$(grep -c '^WAKE ' wakes.log)" -ge 2 ] \
  || fail "route-merger appeared on a known target but the leader was never re-woken"
ok "new residual action on a known target re-wakes the leader"
cd "$CODER"

step "squadd: pending approvals buzz the user exactly once"
cd "$CODER"
"$SCRIPTS/squad_assign.sh" create apn1 implementer sp.md >/dev/null 2>&1 || { echo n > sp2.md; "$SCRIPTS/squad_assign.sh" create apn1 implementer sp2.md >/dev/null; }
"$SCRIPTS/squad_approval.sh" request apnr1 merge apn1 "Ship apn1" "looks good" >/dev/null
bb "$SCRIPTS/squadd.bb" "$CODER" --once >/dev/null 2>&1
grep -q 'user-notify-skipped apnr1' .swarmforge/squad/daemon/squadd.log || fail "pending approval not noticed"
ok "pending approval noticed (wake-cmd none path)"
COUNT1=$(grep -c 'user-notify-skipped apnr1' .swarmforge/squad/daemon/squadd.log)
bb "$SCRIPTS/squadd.bb" "$CODER" --once >/dev/null 2>&1
COUNT2=$(grep -c 'user-notify-skipped apnr1' .swarmforge/squad/daemon/squadd.log)
[ "$COUNT1" = "$COUNT2" ] || fail "approval re-buzzed on second poll"
ok "one buzz per approval (durable dedup)"

step "squad report renders assignments, approvals, events"
OUT="$("$TOOL_ROOT/bin/swarm" squad report)"
expect "report lists assignment" "apn1" <<<"$OUT"
expect "report lists approval" "apnr1" <<<"$OUT"
expect "report has events section" "## Recent events" <<<"$OUT"
OUT="$("$TOOL_ROOT/bin/swarm" squad approve apnr1 fine)"
expect "CLI approve transitions the record" "approved" <<<"$OUT"

echo
echo "SMOKE PASSED ($PASS checks)"
