#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  AI DEV LOOP v2 — «лёгкий сервер»: все проверки идут в GitHub Actions
#
#  Отличия от v1:
#   • Серверу НЕ нужны JDK/Gradle/Android SDK/эмулятор — хватит 2 ГБ RAM.
#   • После реализации сразу push + draft-PR → ждём результат CI
#     (gh pr checks --watch). Красный CI → лог отдаётся Claude, до
#     MAX_ITERATIONS попыток. Зелёный → PR помечается ready + авто-ревью.
#   • Аутентификация: OAuth-токен подписки (CLAUDE_CODE_OAUTH_TOKEN)
#     ИЛИ ANTHROPIC_API_KEY — что задано в env, то и используется.
#   • Если Claude недоступен (упёрлись в лимит подписки) — задача
#     мягко возвращается в очередь до следующего круга таймера.
#   • Telegram-уведомления, когда нужен человек (настройка: TELEGRAM.md).
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

# ─── Конфигурация (переопределяется через /etc/ai-dev.env) ─────────
REPO_DIR="${REPO_DIR:?Задайте REPO_DIR — путь к клону репозитория}"
BASE_BRANCH="${BASE_BRANCH:-main}"
TASK_LABEL="${TASK_LABEL:-ai-task}"
HUMAN_LABEL="${HUMAN_LABEL:-needs-human}"
MAX_ITERATIONS="${MAX_ITERATIONS:-3}"
MAX_BUDGET_USD="${MAX_BUDGET_USD:-5}"   # действует только с API-ключом
CLAUDE_MODEL="${CLAUDE_MODEL:-sonnet}"
AUTO_MERGE="${AUTO_MERGE:-false}"
CI_START_WAIT="${CI_START_WAIT:-30}"    # сек: даём Actions время стартовать
PARTNER_REPO="${PARTNER_REPO:-}"        # owner/repo второго репозитория проекта
                                        # (межрепозиторная блокировка задач)
ALLOWED_AUTHORS="${ALLOWED_AUTHORS:-}"  # GitHub-логины (через пробел), чьи issues
                                        # берём в работу; пусто = только владелец
                                        # gh-токена (защита от prompt injection)
DEV_MODE="${DEV_MODE:-local}"           # local = Claude думает на этом сервере;
                                        # github-app = @claude на GitHub Actions
APP_WAIT_MIN="${APP_WAIT_MIN:-45}"      # github-app: сколько минут ждать PR/фикс
# Замок уникален для каждого репозитория — циклы двух репо не мешают друг другу:
LOCK_FILE="${LOCK_FILE:-/tmp/ai-dev-$(basename "$REPO_DIR").lock}"
# Telegram-уведомления (необязательно; пусто = выключено, см. TELEGRAM.md):
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

exec 9>"$LOCK_FILE"
flock -n 9 || { echo "Другой запуск ещё работает — выходим."; exit 0; }

cd "$REPO_DIR"
LOG_DIR="$REPO_DIR/.ai-logs"
mkdir -p "$LOG_DIR"

log() { echo "[$(date '+%F %T')] $*"; }

# Пинг в Telegram. Молча пропускается, если токен/чат не заданы.
# Ошибка отправки никогда не роняет основной цикл.
tg() {
  if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then return 0; fi
  curl -s --max-time 10 \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" \
    --data-urlencode text="$1" >/dev/null || true
}

# ─── Зависшие авто-merge (конфликт возник ПОСЛЕ постановки в очередь) ──
# gh pr merge --auto просто ставит PR в очередь на слияние, когда позеленеют
# чеки. Если после этого в BASE_BRANCH прилетел другой коммит и вызвал
# конфликт — PR тихо висит вечно: сам процесс уже завершился, TASK_LABEL
# снят, и оркестратор больше никогда не вернётся к этой issue сам. Поэтому
# каждый круг перепроверяем ВСЕ открытые PR наших веток на этот случай —
# до того как браться за следующую задачу.
sweep_stuck_merges() {
  local prs pr url state amr body num already
  prs=$(gh pr list --state open --json url,body,mergeStateStatus,autoMergeRequest,headRefName \
          --jq '[.[] | select(.headRefName | startswith("ai/issue-"))]' 2>/dev/null || echo '[]')
  [ "$(echo "$prs" | jq 'length')" -eq 0 ] && return 0
  while IFS= read -r pr; do
    url=$(echo "$pr" | jq -r .url)
    state=$(echo "$pr" | jq -r .mergeStateStatus)
    amr=$(echo "$pr" | jq -r '.autoMergeRequest // empty')
    body=$(echo "$pr" | jq -r .body)
    [ -z "$amr" ] && continue
    { [ "$state" = "DIRTY" ] || [ "$state" = "CONFLICTING" ]; } || continue
    num=$(echo "$body" | grep -oE '(AI-TASK: #|Closes #)[0-9]+' | grep -oE '[0-9]+' | head -n1 || true)
    [ -z "$num" ] && continue
    already=no
    gh issue view "$num" --json labels --jq '.labels[].name' 2>/dev/null \
      | grep -qx "$HUMAN_LABEL" && already=yes
    [ "$already" = yes ] && continue
    gh pr merge "$url" --disable-auto 2>/dev/null || true
    gh issue edit "$num" --add-label "$HUMAN_LABEL" 2>/dev/null || true
    gh pr comment "$url" --body "⚠️ Авто-merge был поставлен в очередь, но PR теперь конфликтует с \`$BASE_BRANCH\` (кто-то смёржил другой PR раньше). Авто-merge снят — нужен ручной rebase." 2>/dev/null || true
    gh issue comment "$num" --body "⚠️ PR $url ждал авто-merge, но возник конфликт с \`$BASE_BRANCH\` — нужен человек." 2>/dev/null || true
    tg "⚠️ AI dev loop: PR $url (issue #$num) — конфликт после постановки в авто-merge, нужен ручной rebase."
    log "Обнаружил зависший конфликт: $url — передал человеку."
  done < <(echo "$prs" | jq -c '.[]')
}

# ─── Межрепозиторная блокировка ─────────────────────────────────────
# Метка blocked = задача ждёт починки в другом репозитории.
# Маркер в комментарии: BLOCKED-BY: owner/repo#123
# Каждый круг проверяем: блокер закрыт → снимаем метку, задача
# сама возвращается в очередь на перепроверку.
unblock_ready_issues() {
  [ -z "$PARTNER_REPO" ] && return 0
  local ids num marker ref state
  ids=$(gh issue list --state open --label blocked --json number --jq '.[].number')
  for num in $ids; do
    marker=$(gh issue view "$num" --json body,comments \
      --jq '[.body] + [.comments[].body] | join("\n")' \
      | grep -oE 'BLOCKED-BY: [^#[:space:]]+#[0-9]+' | tail -n1 || true)
    [ -z "$marker" ] && continue
    ref="${marker#BLOCKED-BY: }"
    state=$(gh issue view "${ref##*#}" -R "${ref%#*}" --json state --jq .state 2>/dev/null || echo UNKNOWN)
    if [ "$state" = "CLOSED" ]; then
      gh issue edit "$num" --remove-label blocked
      gh issue comment "$num" --body "🔓 Блокировка снята: $ref закрыт. Задача вернулась в очередь на перепроверку."
      log "Разблокировал issue #$num (ждал $ref)"
    fi
  done
}

issue_is_blocked() {  # $1 = номер issue
  gh issue view "$1" --json labels --jq '.labels[].name' | grep -qx blocked
}

# ─── Режим github-app: помощники ────────────────────────────────────
issue_has_marker() {  # $1 = номер issue, $2 = маркер (в начале строки комментария агента)
  # Маркер ищем ТОЛЬКО в комментариях агента (не самого оркестратора) и
  # ТОЛЬКО в начале строки. Иначе инструктаж оркестратора, где сам текст
  # «NEEDS-PARTNER:»/«CANNOT-FIX-HERE:» упомянут по-русски, давал ложное
  # срабатывание — задача блокировалась через ~60 c после старта, ещё до
  # того как агент успевал ответить.
  gh issue view "$1" --json comments \
    --jq --arg me "${SELF_LOGIN:-}" '.comments[] | select(.author.login != $me) | .body' \
    | grep -qE "^[[:space:]]*$2"
}

find_task_pr() {  # $1 = номер issue → URL открытого PR с маркером AI-TASK
  gh pr list --state open \
    --search "\"AI-TASK: #$1\" in:body" \
    --json url --jq '.[0].url // empty'
}

pr_head_sha() { gh pr view "$1" --json headRefOid --jq .headRefOid; }

# Реакция на сигналы агента про партнёрский репозиторий (github-app).
# NEEDS-PARTNER → сервер сам заводит задачу у партнёра и блокирует эту.
# CANNOT-FIX-HERE (или NEEDS-PARTNER при включённой защите) → человеку.
# При срабатывании функция завершает весь скрипт.
handle_partner_signal() {  # $1 = номер issue, $2 = URL PR (может быть пустым)
  [ -z "$PARTNER_REPO" ] && return 0
  if issue_has_marker "$1" "CANNOT-FIX-HERE:" \
     || { [ "$PINGPONG_GUARD" = true ] && issue_has_marker "$1" "NEEDS-PARTNER:"; }; then
    gh issue edit "$1" --add-label "$HUMAN_LABEL"
    [ -n "$2" ] && gh pr close "$2" --comment "🛑 Агент считает, что чинить нужно не здесь, а встречная блокировка запрещена (защита от пинг-понга) — задача передана человеку." || true
    tg "🛑 AI dev loop: #$1 «$TITLE» — агенты двух репо не договорились, где чинить. Нужен ты."
    log "Пинг-понг остановлен, задача у человека."
    exit 0
  fi
  if issue_has_marker "$1" "NEEDS-PARTNER:"; then
    local details new
    details=$(gh issue view "$1" --json comments \
      --jq '[.comments[].body] | join("\n")' | grep -m1 -A20 'NEEDS-PARTNER:')
    new=$(gh issue create -R "$PARTNER_REPO" --label ai-task \
      --title "Из $THIS_REPO#$1: $TITLE" \
      --body "ORIGIN: $THIS_REPO#$1

$details")
    gh issue comment "$1" --body "BLOCKED-BY: $PARTNER_REPO#${new##*/}"
    gh issue edit "$1" --add-label blocked
    [ -n "$2" ] && gh pr close "$2" --comment "⏳ Причина на стороне $PARTNER_REPO — задача заведена там. После починки эта задача автоматически вернётся в очередь." || true
    tg "⏳ AI dev loop: #$1 «$TITLE» заблокирована — причина на стороне $PARTNER_REPO."
    log "Задача #$1 ждёт $PARTNER_REPO. Стоп."
    exit 0
  fi
}

NUM=""
on_error() {
  local line="$1"
  log "❌ Ошибка на строке $line"
  if [ -n "$NUM" ]; then
    gh issue edit "$NUM" --add-label "$HUMAN_LABEL" || true
    gh issue comment "$NUM" --body "🛑 Оркестратор упал с ошибкой (строка $line). Логи: \`.ai-logs/issue-$NUM-*\` на сервере. Нужен человек." || true
  fi
  tg "🛑 AI dev loop: оркестратор упал (строка $line)${NUM:+, задача #$NUM}. Загляни на сервер: journalctl -u ai-dev.service"
  exit 1
}
trap 'on_error $LINENO' ERR

# ─── Аргументы Claude: бюджетный лимит только для API-ключа ────────
CLAUDE_ARGS=( -p --dangerously-skip-permissions --model "$CLAUDE_MODEL" )
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  CLAUDE_ARGS+=( --max-budget-usd "$MAX_BUDGET_USD" )
fi

# Telegram-токен агенту не показываем — вычищаем из окружения:
run_claude() {
  env -u TELEGRAM_BOT_TOKEN -u TELEGRAM_CHAT_ID claude "${CLAUDE_ARGS[@]}" "$1"
}

# ═══ 1. Следующая задача из очереди ═════════════════════════════════
git fetch origin
git checkout "$BASE_BRANCH"
git reset --hard "origin/$BASE_BRANCH"

# Сначала ищем PR, чей авто-merge завис из-за конфликта, возникшего уже
# после постановки в очередь (см. sweep_stuck_merges выше):
sweep_stuck_merges

# Возвращаем в очередь задачи, чей блокер в соседнем репо закрыт:
unblock_ready_issues

# Защита от prompt injection: в очередь попадают ТОЛЬКО issues от
# доверенных авторов. По умолчанию — владелец gh-токена; межрепозиторные
# задачи агент создаёт от того же аккаунта, поэтому они тоже проходят.
# Логин владельца токена = аккаунт, от которого оркестратор пишет
# комментарии. Нужен, чтобы отличать инструктаж оркестратора от реального
# сигнала агента в issue_has_marker (см. фикс ложного NEEDS-PARTNER).
SELF_LOGIN=$(gh api user --jq .login)
if [ -z "$ALLOWED_AUTHORS" ]; then
  ALLOWED_AUTHORS="$SELF_LOGIN"
fi
AUTHOR_FILTER=""
for a in $ALLOWED_AUTHORS; do AUTHOR_FILTER+=" author:$a"; done

ISSUE_JSON=$(gh issue list --state open \
  --search "label:$TASK_LABEL -label:$HUMAN_LABEL -label:blocked$AUTHOR_FILTER sort:created-asc" \
  --json number,title,body --limit 1)

if [ "$(echo "$ISSUE_JSON" | jq 'length')" -eq 0 ]; then
  log "Очередь пуста — нечего делать. ✅"
  exit 0
fi

NUM=$(echo "$ISSUE_JSON"   | jq -r '.[0].number')
TITLE=$(echo "$ISSUE_JSON" | jq -r '.[0].title')
BODY=$(echo "$ISSUE_JSON"  | jq -r '.[0].body // ""')
BRANCH="ai/issue-$NUM"

log "Задача: #$NUM — $TITLE (режим: $DEV_MODE)"
if [ "$DEV_MODE" = "local" ]; then
  git checkout -B "$BRANCH"
fi
gh issue comment "$NUM" --body "🤖 Взял в работу."

# Инструкция про ошибки на стороне второго репозитория (если он задан).
# Защита от пинг-понга: задача, пришедшая ИЗ партнёрского репо (маркер
# ORIGIN в описании) или уже блокировавшаяся 2 раза, встречную блокировку
# создавать НЕ может — только остановка без коммитов → needs-human.
BLOCK_HINT=""
PINGPONG_GUARD=false
if [ -n "$PARTNER_REPO" ]; then
  THIS_REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
  BLOCK_MARKERS=$(gh issue view "$NUM" --json comments \
    --jq '[.comments[].body] | join("\n")' | grep -c 'BLOCKED-BY:' || true)
  if echo "$BODY" | grep -qE "ORIGIN: ${PARTNER_REPO}#[0-9]+" \
     || [ "${BLOCK_MARKERS:-0}" -ge 2 ]; then
    PINGPONG_GUARD=true
    if [ "$DEV_MODE" = "github-app" ]; then
      BLOCK_HINT="

ВАЖНО: эта задача либо пришла из $PARTNER_REPO, либо уже блокировалась
на него дважды. Перекладывать её обратно ЗАПРЕЩЕНО (защита от
бесконечного пинг-понга). Если ты уверен, что причина всё-таки не в
этом репозитории, — НЕ открывай PR и не делай заглушек, а оставь на
этом issue комментарий, начинающийся строкой CANNOT-FIX-HERE: с
объяснением. Система позовёт человека."
    else
      BLOCK_HINT="

ВАЖНО: эта задача либо пришла из $PARTNER_REPO, либо уже блокировалась
на него дважды. Создавать встречные задачи в $PARTNER_REPO ЗАПРЕЩЕНО
(защита от бесконечного пинг-понга между репозиториями). Если ты
уверен, что причина всё-таки не в этом репозитории, — не делай никаких
коммитов и обходных заглушек, просто заверши работу: система сама
позовёт человека."
    fi
  else
    if [ "$DEV_MODE" = "github-app" ]; then
      BLOCK_HINT="

ВАЖНО — межрепозиторные ошибки. Если станет очевидно, что причина
проблемы НЕ в этом репозитории, а на стороне $PARTNER_REPO (их API
отвечает ошибкой или контракт не совпадает) — НЕ чини это здесь и не
делай обходных заглушек. Вместо открытия PR оставь на этом issue
комментарий, начинающийся строкой NEEDS-PARTNER: с подробным описанием
проблемы и логами. Сервер сам заведёт задачу в $PARTNER_REPO и вернётся
к этой задаче после починки."
    else
      BLOCK_HINT="

ВАЖНО — межрепозиторные ошибки. Если станет очевидно, что причина
проблемы НЕ в этом репозитории, а на стороне $PARTNER_REPO (например,
их API отвечает ошибкой или контракт не совпадает с ожидаемым) — НЕ
пытайся чинить это здесь и не делай обходных заглушек. Вместо этого
выполни ровно три команды и заверши работу:
1) gh issue create -R $PARTNER_REPO --label ai-task --title \"<краткая суть проблемы>\" --body \"ORIGIN: $THIS_REPO#$NUM
<подробности, логи, что именно не так>\"
   (первая строка body — ровно этот маркер ORIGIN, он обязателен)
2) gh issue comment $NUM --body \"BLOCKED-BY: $PARTNER_REPO#<номер созданного issue>\"
3) gh issue edit $NUM --add-label blocked"
    fi
  fi
fi

# ═══ 2. Реализация ══════════════════════════════════════════════════
if [ "$DEV_MODE" = "local" ]; then

if ! run_claude "Задача из GitHub issue #$NUM: «$TITLE»

$BODY

Реализуй эту задачу в текущем репозитории.
Правила:
- следуй инструкциям из CLAUDE.md в корне репозитория;
- делай атомарные коммиты (git add + git commit) с понятными сообщениями;
- НИЧЕГО не пушь и не переключай ветки;
- ветку $BASE_BRANCH не трогай.$BLOCK_HINT" \
  2>&1 | tee "$LOG_DIR/issue-$NUM-impl.log"; then
  # Claude не отработал (скорее всего — лимит подписки). Мягко отступаем:
  gh issue comment "$NUM" --body "⏸️ Claude сейчас недоступен (возможно, исчерпан лимит подписки). Задача остаётся в очереди — попробую в следующий круг."
  git checkout "$BASE_BRANCH"
  git branch -D "$BRANCH" || true
  log "Claude недоступен — задача возвращена в очередь."
  exit 0
fi

# Агент мог заблокировать задачу на партнёрский репозиторий:
if [ -n "$PARTNER_REPO" ] && issue_is_blocked "$NUM"; then
  if [ "$PINGPONG_GUARD" = true ]; then
    # Агент нарушил запрет — жёстко останавливаем пинг-понг:
    gh issue edit "$NUM" --remove-label blocked --add-label "$HUMAN_LABEL"
    gh issue comment "$NUM" --body "🛑 Встречная блокировка запрещена (защита от пинг-понга) — задача передана человеку."
    tg "🛑 AI dev loop: #$NUM «$TITLE» — агенты двух репо не договорились, где чинить. Нужен ты."
    git checkout "$BASE_BRANCH"; git branch -D "$BRANCH" || true
    log "Пинг-понг остановлен, задача у человека."
    exit 0
  fi
  tg "⏳ AI dev loop: #$NUM «$TITLE» заблокирована — причина на стороне $PARTNER_REPO, агент завёл там задачу. Вернусь к ней после починки."
  git checkout "$BASE_BRANCH"
  git branch -D "$BRANCH" || true
  log "Задача #$NUM ждёт $PARTNER_REPO. Стоп."
  exit 0
fi

# Агент обязан был что-то закоммитить:
if [ "$(git rev-list --count "origin/$BASE_BRANCH"..HEAD)" -eq 0 ]; then
  NOCOMMIT_WHY="Похоже, задача сформулирована непонятно."
  if [ "$PINGPONG_GUARD" = true ]; then
    NOCOMMIT_WHY="Задача связана с $PARTNER_REPO, и агент считает, что чинить нужно не здесь, но встречная блокировка запрещена (защита от пинг-понга)."
  fi
  gh issue edit "$NUM" --add-label "$HUMAN_LABEL"
  gh issue comment "$NUM" --body "🛑 Агент завершил работу без единого коммита. $NOCOMMIT_WHY Нужен человек."
  tg "🛑 AI dev loop: #$NUM «$TITLE» — агент остановился без коммитов. $NOCOMMIT_WHY"
  exit 0
fi

else
  # ═══ 2-app. Поручаем задачу @claude на GitHub Actions ═════════════
  gh issue comment "$NUM" --body "@claude Реализуй задачу из этого issue.
Требования:
- следуй CLAUDE.md репозитория;
- где возможно, прогони сборку и тесты у себя перед пушем;
- открой pull request в ветку $BASE_BRANCH;
- в описании PR обязательно укажи две строки: «AI-TASK: #$NUM» и «Closes #$NUM».$BLOCK_HINT"

  log "Задача поручена @claude, жду появления PR (до $APP_WAIT_MIN мин)…"
  PR_URL=""
  DEADLINE=$(( $(date +%s) + APP_WAIT_MIN * 60 ))
  while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    sleep 60
    handle_partner_signal "$NUM" ""
    PR_URL=$(find_task_pr "$NUM")
    [ -n "$PR_URL" ] && break
  done

  if [ -z "$PR_URL" ]; then
    gh issue edit "$NUM" --add-label "$HUMAN_LABEL"
    gh issue comment "$NUM" --body "🛑 @claude не открыл PR за $APP_WAIT_MIN минут — нужен человек (ход работы: комментарии и вкладка Actions)."
    tg "🛑 AI dev loop: #$NUM «$TITLE» — PR от @claude не появился за $APP_WAIT_MIN мин. Нужен ты."
    exit 0
  fi
  log "PR от @claude: $PR_URL"
fi  # DEV_MODE

# ═══ 3. PR → цикл: ждём CI, чиним, снова ждём ══════════════════════
if [ "$DEV_MODE" = "local" ]; then
  git push -u origin "$BRANCH" --force-with-lease

  PR_URL=$(gh pr create --draft --base "$BASE_BRANCH" --head "$BRANCH" \
    --title "AI: $TITLE" \
    --body "Closes #$NUM

Автономная реализация (ai-dev loop v2). Проверки выполняет GitHub Actions.")

  log "Draft-PR создан: $PR_URL"
fi

SUCCESS=false
for i in $(seq 1 "$MAX_ITERATIONS"); do
  log "Жду результаты CI (попытка $i из $MAX_ITERATIONS)…"
  sleep "$CI_START_WAIT"   # даём Actions время создать run

  if gh pr checks "$PR_URL" --watch; then
    SUCCESS=true
    log "CI зелёный ✅"
    break
  fi

  log "CI красный — забираю лог упавших шагов"
  RUN_ID=$(gh run list --branch "$BRANCH" --limit 1 \
             --json databaseId --jq '.[0].databaseId' || true)
  FAIL_TAIL=$( { gh run view "$RUN_ID" --log-failed 2>/dev/null || \
                 echo "(не удалось скачать лог CI)"; } | tail -n 150 )
  echo "$FAIL_TAIL" > "$LOG_DIR/issue-$NUM-ci-fail-$i.log"

  # Последняя попытка исчерпана — чинить больше не даём
  [ "$i" -eq "$MAX_ITERATIONS" ] && break

  if [ "$DEV_MODE" = "local" ]; then

  run_claude "CI на GitHub упал (попытка $i из $MAX_ITERATIONS). Конец лога упавших шагов:

\`\`\`
$FAIL_TAIL
\`\`\`

Найди причину, исправь код и закоммить исправление. Ничего не пушь.$BLOCK_HINT" \
    2>&1 | tee "$LOG_DIR/issue-$NUM-fix-$i.log" \
    || log "⚠️ claude завершился с ошибкой, идём дальше"

  # Агент решил, что причина на стороне партнёрского репозитория:
  if [ -n "$PARTNER_REPO" ] && issue_is_blocked "$NUM"; then
    if [ "$PINGPONG_GUARD" = true ]; then
      gh issue edit "$NUM" --remove-label blocked --add-label "$HUMAN_LABEL"
      gh pr close "$PR_URL" --comment "🛑 Встречная блокировка запрещена (защита от пинг-понга) — задача передана человеку."
      tg "🛑 AI dev loop: #$NUM «$TITLE» — агенты двух репо не договорились, где чинить. Нужен ты: $PR_URL"
      log "Пинг-понг остановлен, задача у человека."
      exit 0
    fi
    gh pr close "$PR_URL" --comment "⏳ Причина на стороне $PARTNER_REPO — агент завёл там задачу (см. маркер BLOCKED-BY в issue #$NUM). PR закрыт; после починки задача автоматически вернётся в очередь и будет перепроверена."
    tg "⏳ AI dev loop: #$NUM «$TITLE» заблокирована — причина на стороне $PARTNER_REPO. Вернусь после починки."
    log "Задача #$NUM ждёт $PARTNER_REPO. Стоп."
    exit 0
  fi

  git push --force-with-lease

  else
    # ─ github-app: просим @claude починить прямо в этом PR ──────────
    OLD_SHA=$(pr_head_sha "$PR_URL")
    gh pr comment "$PR_URL" --body "@claude CI упал (попытка $i из $MAX_ITERATIONS). Конец лога упавших шагов:

\`\`\`
$FAIL_TAIL
\`\`\`

Найди причину, исправь и запушь коммит в эту же ветку.$BLOCK_HINT"
    log "Жду фикс от @claude (до $APP_WAIT_MIN мин)…"
    DEADLINE=$(( $(date +%s) + APP_WAIT_MIN * 60 ))
    FIXED=false
    while [ "$(date +%s)" -lt "$DEADLINE" ]; do
      sleep 60
      handle_partner_signal "$NUM" "$PR_URL"
      if [ "$(pr_head_sha "$PR_URL")" != "$OLD_SHA" ]; then FIXED=true; break; fi
    done
    if [ "$FIXED" != true ]; then
      log "Фикс от @claude не пришёл за $APP_WAIT_MIN мин — передаю человеку."
      break
    fi
  fi
done

# ═══ 4a. Не справился → зовём человека ══════════════════════════════
if [ "$SUCCESS" != true ]; then
  gh issue edit "$NUM" --add-label "$HUMAN_LABEL"
  gh issue comment "$NUM" --body "🛑 После $MAX_ITERATIONS попыток CI всё ещё красный — нужен человек.
PR (draft): $PR_URL. Логи CI: вкладка Checks в PR."
  tg "🛑 AI dev loop: #$NUM «$TITLE» — $MAX_ITERATIONS попытки, CI всё ещё красный. Нужна твоя помощь: $PR_URL"
  log "Передал человеку. Стоп."
  exit 0
fi

# ═══ 4b. Справился → PR ready + авто-ревью ═════════════════════════
gh pr ready "$PR_URL" 2>/dev/null || true   # PR от App может быть уже не draft

REVIEW=$(gh pr diff "$PR_URL" | \
  env -u TELEGRAM_BOT_TOKEN -u TELEGRAM_CHAT_ID claude "${CLAUDE_ARGS[@]}" \
  "Ты строгий код-ревьюер. На stdin — дифф pull request'а.
Проверь: безопасность (секреты, инъекции, права), корректность логики,
обработку ошибок, качество кода. Пиши кратко и по делу, по-русски.
САМОЙ ПОСЛЕДНЕЙ строкой выведи ровно одно из двух:
VERDICT: APPROVE
VERDICT: REQUEST_CHANGES")

gh pr comment "$PR_URL" --body "## 🤖 Авто-ревью

$REVIEW"

# ═══ 5. Merge ═══════════════════════════════════════════════════════
# mergeStateStatus проверяем ДО авто-merge: --auto у gh просто ставит PR
# в очередь на слияние, когда чеки позеленеют, но молчит, если уже сейчас
# есть конфликт с BASE_BRANCH — такой PR завис бы незамеченным (задача уже
# сдана с рук, TASK_LABEL снят). Более поздний конфликт (появившийся уже
# после этого прогона) ловит sweep_stuck_merges в начале следующего круга.
MERGE_STATE=$(gh pr view "$PR_URL" --json mergeStateStatus --jq .mergeStateStatus 2>/dev/null || echo UNKNOWN)
CONFLICT=false
if [ "$MERGE_STATE" = "DIRTY" ] || [ "$MERGE_STATE" = "CONFLICTING" ]; then
  CONFLICT=true
fi

if echo "$REVIEW" | grep -q "VERDICT: APPROVE"; then
  if [ "$CONFLICT" = true ]; then
    gh issue edit "$NUM" --add-label "$HUMAN_LABEL"
    gh issue comment "$NUM" --body "⚠️ Ревью одобрено, но PR конфликтует с \`$BASE_BRANCH\` — авто-merge не запускаю. Нужен ручной rebase: $PR_URL"
    tg "⚠️ AI dev loop: #$NUM «$TITLE» одобрен ревью, но конфликт с $BASE_BRANCH — нужен ручной rebase: $PR_URL"
    log "PR одобрен, но конфликтует — передал человеку."
  elif [ "$AUTO_MERGE" = "true" ]; then
    gh pr merge "$PR_URL" --squash --auto
    gh issue comment "$NUM" --body "✅ Ревью пройдено, PR поставлен на авто-merge: $PR_URL"
    tg "✅ AI dev loop: #$NUM «$TITLE» готово и уходит в авто-merge: $PR_URL"
    log "Авто-merge включён для $PR_URL"
  else
    gh issue comment "$NUM" --body "👀 PR готов и ждёт вашего решения: $PR_URL"
    tg "👀 AI dev loop: #$NUM «$TITLE» — PR готов, глянь, когда будет минутка: $PR_URL"
    log "PR ждёт человека: $PR_URL"
  fi
else
  # VERDICT: REQUEST_CHANGES — раньше это тонуло в том же нейтральном
  # «глянь, когда будет минутка», что и обычный approve без авто-merge, и
  # без HUMAN_LABEL. Из-за этого PR мог зависнуть незамеченным. Теперь —
  # отдельная, тревожная ветка с явной меткой.
  gh issue edit "$NUM" --add-label "$HUMAN_LABEL"
  gh issue comment "$NUM" --body "⚠️ Авто-ревью запросило правки (VERDICT: REQUEST_CHANGES) — нужен человек: $PR_URL"
  tg "⚠️ AI dev loop: #$NUM «$TITLE» — ревью запросило правки, нужен ты: $PR_URL"
  log "Ревью запросило правки — передал человеку."
fi

gh issue edit "$NUM" --remove-label "$TASK_LABEL"
log "Итерация завершена. 🎉"
