#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  AI dev loop — СМОТРИТЕЛЬ БЭКЛОГА
#
#  Раз в неделю будит Claude и даёт ему два поручения подряд:
#   1. Разобрать затор: вернуть в очередь то, что уже можно делать,
#      закрыть протухшее, оставить человеку только настоящее.
#   2. Если после разбора очередь ВСЁ РАВНО пуста — завести до
#      MAX_NEW_TASKS новых задач по результатам анализа репозитория.
#
#  Порядок принципиален. На 2026-09-19 в двух репо было 113 открытых
#  задач и 0 в очереди: конвейер стоял не от голода, а от затора.
#  Заводить новое поверх затора — гнать задачи в ту же пробку.
#
#  Конфигурация — тот же /etc/ai-dev-<repo>.env, что и у оркестратора.
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

REPO_DIR="${REPO_DIR:?Задайте REPO_DIR — путь к клону репозитория}"
BASE_BRANCH="${BASE_BRANCH:-main}"
TASK_LABEL="${TASK_LABEL:-ai-task}"
HUMAN_LABEL="${HUMAN_LABEL:-needs-human}"
CLAUDE_MODEL="${CLAUDE_MODEL:-sonnet}"
MAX_BUDGET_USD="${MAX_BUDGET_USD:-5}"
MAX_NEW_TASKS="${MAX_NEW_TASKS:-5}"   # жёсткий потолок за один запуск
ALLOWED_AUTHORS="${ALLOWED_AUTHORS:-}"
PARTNER_REPO="${PARTNER_REPO:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
# Замок общий с оркестратором: смотритель переставляет метки, и делать
# это под работающей итерацией нельзя.
LOCK_FILE="${LOCK_FILE:-/tmp/ai-dev-$(basename "$REPO_DIR").lock}"
KEEPER_INTERVAL_DAYS="${KEEPER_INTERVAL_DAYS:-7}"

cd "$REPO_DIR"
LOG_DIR="$REPO_DIR/.ai-logs"
mkdir -p "$LOG_DIR"
STAMP_FILE="$LOG_DIR/.backlog-keeper-last"

# Таймер тикает раз в час, а работаем раз в KEEPER_INTERVAL_DAYS суток.
# Недельный таймер здесь не годится: замок общий с оркестратором, и если в
# момент срабатывания шла итерация (а она может идти часами), смотритель
# пропустил бы не круг, а всю неделю. Почасовой тик просто попробует позже.
if [ -e "$STAMP_FILE" ]; then
  age=$(( ( $(date +%s) - $(stat -c %Y "$STAMP_FILE") ) / 86400 ))
  if [ "$age" -lt "$KEEPER_INTERVAL_DAYS" ]; then
    exit 0
  fi
fi

exec 9>"$LOCK_FILE"
flock -n 9 || { echo "Итерация ai-dev идёт — смотритель попробует через час."; exit 0; }

log() { echo "[$(date '+%F %T')] $*"; }

tg() {
  if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then return 0; fi
  curl -s --max-time 10 \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" \
    --data-urlencode text="$1" >/dev/null || true
}

on_error() {
  log "❌ Смотритель упал на строке $1"
  tg "🛑 AI dev loop: смотритель бэклога ($(basename "$REPO_DIR")) упал на строке $1."
  exit 1
}
trap 'on_error $LINENO' ERR

CLAUDE_ARGS=( -p --dangerously-skip-permissions --model "$CLAUDE_MODEL" )
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  CLAUDE_ARGS+=( --max-budget-usd "$MAX_BUDGET_USD" )
fi
run_claude() {
  env -u TELEGRAM_BOT_TOKEN -u TELEGRAM_CHAT_ID claude "${CLAUDE_ARGS[@]}" "$1"
}

git fetch origin
git checkout "$BASE_BRANCH"
git reset --hard "origin/$BASE_BRANCH"

THIS_REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
SELF_LOGIN=$(gh api user --jq .login)
[ -z "$ALLOWED_AUTHORS" ] && ALLOWED_AUTHORS="$SELF_LOGIN"
AUTHOR_FILTER=""
for a in $ALLOWED_AUTHORS; do AUTHOR_FILTER+=" author:$a"; done

# Очередь считаем ровно тем же запросом, что и оркестратор: метка задачи,
# без needs-human, без blocked и только от доверенных авторов. Простое
# `gh issue list --label ai-task` даёт совсем другое число.
queue_size() {
  gh issue list --state open \
    --search "label:$TASK_LABEL -label:$HUMAN_LABEL -label:blocked$AUTHOR_FILTER" \
    --json number --jq 'length'
}

STAMP=$(date +%F)
BEFORE=$(queue_size)
log "Очередь до разбора: $BEFORE"

# ═══ 1. Разбор затора ═══════════════════════════════════════════════
run_claude "Ты смотритель бэклога репозитория $THIS_REPO. Разбери затор.
Партнёрский репозиторий проекта: ${PARTNER_REPO:-(не задан)}.

ОЧЕРЕДЬ задач AI-агента — это ровно такой запрос:
  gh issue list --state open --search 'label:$TASK_LABEL -label:$HUMAN_LABEL -label:blocked$AUTHOR_FILTER'
Сейчас в ней $BEFORE задач. Твоя цель — вернуть в неё то, что уже можно
делать, и снять с людей то, что людям больше не нужно.

Разбери три группы.

1) Задачи с меткой \`$HUMAN_LABEL\`. По каждой выясни из комментариев, ПОЧЕМУ
   она там. Если причина уже отпала — блокер закрыт, нужный PR влит,
   контракт появился, задача сделана другим PR — сними метку \`$HUMAN_LABEL\`
   и напиши комментарием, что именно изменилось. Если задача дублирует
   закрытую — закрой со ссылкой на оригинал. Если человек действительно
   нужен — НЕ трогай её вовсе.

2) Задачи с меткой \`blocked\`. Рабочий маркер — комментарий вида
   \`BLOCKED-BY: owner/repo#N\`; без него автоматика разблокировать не умеет.
   Если блокер назван только в заголовке или в теле — проверь его состояние:
   закрыт → сними \`blocked\`; открыт → добавь недостающий комментарий
   \`BLOCKED-BY: owner/repo#N\`, чтобы задача разблокировалась сама.

3) Открытые pull request'ы с маркером \`AI-TASK: #N\` или \`Closes #N\`.
   Если два PR закрывают одну и ту же issue — оставь более полный, второй
   закрой с объяснением. Если PR конфликтует с \`$BASE_BRANCH\` или висит без
   движения — напиши в нём коротким комментарием, чего он ждёт.

ЧТО МОЖНО: gh issue edit (метки), gh issue comment, gh issue close,
gh pr comment, gh pr close. Читать код и историю — сколько нужно.

ЧТО НЕЛЬЗЯ: менять код, коммитить, пушить, мержить PR, создавать новые
issue (это отдельный шаг, он будет после тебя), трогать репозиторий
${PARTNER_REPO:-партнёра}.

Действуй консервативно: сомневаешься — не трогай. Лучше оставить лишнее
человеку, чем вернуть в очередь то, что не готово.

В конце выведи короткую сводку: что разблокировал, что закрыл, что оставил
человеку и почему." 2>&1 | tee "$LOG_DIR/backlog-triage-$STAMP.log"

AFTER=$(queue_size)
log "Очередь после разбора: $AFTER (было $BEFORE)"

# Недельный проход состоялся — отмечаемся до того, как решать про новые
# задачи: иначе сбой на втором шаге заставил бы повторять разбор каждый час.
touch "$STAMP_FILE"

# ═══ 2. Новые задачи — только в пустую очередь ══════════════════════
if [ "$AFTER" -gt 0 ]; then
  log "В очереди $AFTER задач — новые не нужны. Готово."
  tg "🧹 AI dev loop ($(basename "$REPO_DIR")): разбор бэклога вернул в очередь $AFTER задач (было $BEFORE). Новые не заводил."
  exit 0
fi

log "Очередь пуста и после разбора — завожу новые задачи (до $MAX_NEW_TASKS)."

run_claude "Ты смотритель бэклога репозитория $THIS_REPO. Очередь задач
AI-агента пуста даже после разбора затора — значит нужна новая работа.

Заведи НЕ БОЛЬШЕ $MAX_NEW_TASKS задач. Это жёсткий потолок.

Откуда брать: следуй CLAUDE.md репозитория, посмотри документацию
(docs/, ADR, CHANGELOG), расхождения контракта с реальностью, замечания
авто-ревью в открытых PR, места с TODO/FIXME, дыры в тестах, вещи,
которые прошлые задачи осознанно оставили на потом.

Требования к каждой задаче:
- ПЕРЕД созданием найди, нет ли такой уже: поиском и по открытым, и по
  закрытым issue. Есть — не заводи, это главный источник мусора;
- задача должна быть выполнима в ЭТОМ репозитории целиком. Всё, что
  упирается в ${PARTNER_REPO:-партнёрский репозиторий}, заводить нельзя:
  для этого у цикла есть собственный механизм NEEDS-PARTNER;
- размер — одна задача на один PR, а не эпик;
- в теле: что не так сейчас, что должно стать, как проверить результат;
- создавать так: gh issue create --label $TASK_LABEL --title '...' --body '...'

ЧТО НЕЛЬЗЯ: менять код, коммитить, пушить, трогать существующие issue и PR,
заводить задачи в ${PARTNER_REPO:-партнёрском репозитории}, превышать потолок.

В конце выведи список заведённого: номер, заголовок, одна строка обоснования." \
  2>&1 | tee "$LOG_DIR/backlog-new-$STAMP.log"

NEW=$(queue_size)
log "Заведено задач: $NEW. Готово."
tg "🌱 AI dev loop ($(basename "$REPO_DIR")): очередь была пуста, смотритель завёл $NEW задач (потолок $MAX_NEW_TASKS)."
