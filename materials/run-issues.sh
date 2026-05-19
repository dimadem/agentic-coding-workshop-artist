#!/usr/bin/env bash
# materials/run-issues.sh
# Прогоняет файлы из materials/issues/todo/ через ralph-loop по одному.
#
# Workflow:
#   1. /to-issues кладёт markdown-issue в materials/issues/todo/
#   2. ./materials/run-issues.sh: для каждой issue стартует ralph-loop,
#      ждёт promise или max-iterations, затем берёт следующую.
#
# Env-override:
#   MAX_ITERATIONS  (default 30)
#   PROMISE         (default DONE)
#   PERMISSION_MODE (default bypassPermissions — headless без промптов)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ISSUES_DIR="$SCRIPT_DIR/issues"
TODO="$ISSUES_DIR/todo"
DOING="$ISSUES_DIR/doing"
DONE_="$ISSUES_DIR/done"
FAILED="$ISSUES_DIR/failed"
LOG_DIR="$SCRIPT_DIR/logs"

mkdir -p "$TODO" "$DOING" "$DONE_" "$FAILED" "$LOG_DIR"

MAX_ITERATIONS="${MAX_ITERATIONS:-30}"
PROMISE="${PROMISE:-DONE}"
PERMISSION_MODE="${PERMISSION_MODE:-bypassPermissions}"
STATE_FILE="$PROJECT_ROOT/.claude/ralph-loop.local.md"

cd "$PROJECT_ROOT"

if [[ -f "$STATE_FILE" ]]; then
  echo "[run-issues] ВНИМАНИЕ: активный ralph-loop в $STATE_FILE"
  echo "             Очисти: rm '$STATE_FILE'  (или /ralph-loop:cancel-ralph) и перезапусти."
  exit 1
fi

build_prompt() {
  local issue_path="$1"
  cat <<EOF
Реализуй задачу из файла \`$issue_path\`.

Алгоритм на каждой итерации:
1. Прочитай файл задачи целиком.
2. Посмотри состояние кода — что уже сделано на прошлых итерациях.
3. Сделай следующий шаг к выполнению критериев из секции «Критерии выполненной задачи».
4. Отметь выполненные критерии \`[ ]\` → \`[x]\` прямо в файле задачи.
5. Запусти \`just audit\` — если красное, чини.
6. Если ВСЕ критерии \`[x]\` И \`just audit\` зелёный — выведи \`<promise>$PROMISE</promise>\`.

Жёсткие правила:
- Не ври. \`<promise>$PROMISE</promise>\` — ТОЛЬКО когда реально все критерии \`[x]\` и аудит зелёный.
- Не комить и не пушай — это делает человек после ревью.
- Работай только с \`$issue_path\` и кодом, который её закрывает. Соседние issue не трогай.
- Если критерий физически невыполним (нужно архитектурное решение или внешний доступ) — оставь \`[ ]\`, допиши в issue секцию «## Заблокировано» с пояснением и НЕ выводи promise.
- Если \`just audit\` падает по причине, не связанной с задачей (предсуществующая ошибка) — задокументируй это в той же секции и НЕ выводи promise.
EOF
}

write_state() {
  local prompt="$1"
  mkdir -p "$(dirname "$STATE_FILE")"
  # session_id пустой → хук работает в любой сессии (см. stop-hook.sh).
  cat > "$STATE_FILE" <<EOF
---
active: true
iteration: 1
session_id:
max_iterations: $MAX_ITERATIONS
completion_promise: "$PROMISE"
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---

$prompt
EOF
}

run_one() {
  local issue_file="$1"
  local base
  base="$(basename "$issue_file")"
  local rel_path="materials/issues/doing/$base"
  local log_file="$LOG_DIR/${base%.md}-$(date +%Y%m%d-%H%M%S).log"

  echo "[run-issues] start: $base"
  echo "[run-issues]   log: ${log_file#$PROJECT_ROOT/}"

  mv "$TODO/$base" "$DOING/$base"

  local prompt
  prompt="$(build_prompt "$rel_path")"
  write_state "$prompt"

  set +e
  claude -p "$prompt" --permission-mode "$PERMISSION_MODE" >"$log_file" 2>&1
  local status=$?
  set -e

  # Хук удаляет state-файл при promise / max-iterations / ошибке.
  # Отсутствие файла = ralph честно вышел (по promise или по лимиту).
  if [[ ! -f "$STATE_FILE" ]]; then
    mv "$DOING/$base" "$DONE_/$base"
    echo "[run-issues] done:  $base"
  else
    mv "$DOING/$base" "$FAILED/$base"
    rm -f "$STATE_FILE"
    echo "[run-issues] FAIL: $base (exit=$status — см. ${log_file#$PROJECT_ROOT/})"
  fi
}

cleanup() {
  echo
  echo "[run-issues] прерван — возвращаю doing/* обратно в todo/"
  rm -f "$STATE_FILE"
  shopt -s nullglob
  for f in "$DOING"/*.md; do
    mv "$f" "$TODO/$(basename "$f")"
  done
  exit 130
}
trap cleanup INT TERM

shopt -s nullglob
while true; do
  next=""
  for f in "$TODO"/*.md; do
    next="$f"
    break
  done
  if [[ -z "$next" ]]; then
    echo "[run-issues] очередь пуста: ${TODO#$PROJECT_ROOT/}"
    break
  fi
  run_one "$next"
done
