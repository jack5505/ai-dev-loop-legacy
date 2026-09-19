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
MAX_REVIEW_ROUNDS="${MAX_REVIEW_ROUNDS:-2}"  # сколько раз отдавать агенту
                                        # замечания ревью, прежде чем звать человека
PR_STALE_DAYS="${PR_STALE_DAYS:-3}"     # открытый AI-PR без движения дольше
                                        # этого срока попадает в сводку сторожа
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
APP_WAIT_MIN="${APP_WAIT_MIN:-180}"     # github-app: сколько минут ждать PR/фикс
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

# ─── Межрепозиторная блокировка ─────────────────────────────────────
# Метка blocked = задача ждёт починки в другом репозитории.
# Маркер в комментарии: BLOCKED-BY: owner/repo#123
# Каждый круг проверяем: блокер закрыт → снимаем метку, задача
# сама возвращается в очередь на перепроверку.
unblock_ready_issues() {
  [ -z "$PARTNER_REPO" ] && return 0
  local rows num title marker ref state
  rows=$(gh issue list --state open --label blocked --json number,title \
    --jq '.[] | "\(.number)\t\(.title)"')
  while IFS=$'\t' read -r num title; do
    [ -z "$num" ] && continue
    marker=$(gh issue view "$num" --json body,comments \
      --jq '[.body] + [.comments[].body] | join("\n")' \
      | grep -oE 'BLOCKED-BY: [^#[:space:]]+#[0-9]+' | tail -n1 || true)
    if [ -z "$marker" ]; then
      # Метка blocked без маркера BLOCKED-BY — задача ждёт того, чего система
      # не знает. Раньше тут был молчаливый `continue`, и такая задача пропадала
      # навсегда: из очереди исключена (-label:blocked), в needs-human не
      # попадает, ни в один алерт не приходит. К 2026-09-19 так накопилось
      # 10 штук начиная с 03.09 — часть ждала блокеров, закрытых ещё неделю
      # назад. Теперь такие задачи сразу уходят человеку.
      gh issue edit "$num" --remove-label blocked --add-label "$HUMAN_LABEL"
      gh issue comment "$num" --body "🛑 Метка \`blocked\` стоит без маркера \`BLOCKED-BY: owner/repo#N\`, поэтому система не знает, чего эта задача ждёт, и разблокировать её сама не может.

Что сделать: либо добавь комментарий вида \`BLOCKED-BY: $PARTNER_REPO#<номер>\` и верни метку \`blocked\` — тогда задача разблокируется автоматически, когда блокер закроют; либо просто сними \`$HUMAN_LABEL\`, чтобы задача вернулась в очередь."
      tg "🛑 AI dev loop: #$num «$title» помечена blocked без маркера BLOCKED-BY — не знаю, чего она ждёт. Нужен ты."
      log "Issue #$num: blocked без BLOCKED-BY — передал человеку."
      continue
    fi
    ref="${marker#BLOCKED-BY: }"
    state=$(gh issue view "${ref##*#}" -R "${ref%#*}" --json state --jq .state 2>/dev/null || echo UNKNOWN)
    if [ "$state" = "CLOSED" ]; then
      gh issue edit "$num" --remove-label blocked
      gh issue comment "$num" --body "🔓 Блокировка снята: $ref закрыт. Задача вернулась в очередь на перепроверку."
      log "Разблокировал issue #$num (ждал $ref)"
    fi
  done <<< "$rows"
}

issue_is_blocked() {  # $1 = номер issue
  gh issue view "$1" --json labels --jq '.labels[].name' | grep -qx blocked
}

# ─── Сторож открытых PR ─────────────────────────────────────────────
# Итерация заканчивается на `remove-label ai-task`: задача уходит из очереди,
# а открытый PR после этого не сторожит никто. К 2026-09-19 так накопилось
# 13 открытых PR (старшему 10 дней), пять из них CONFLICTING, и цикл об этом
# не знал — слова `mergeable` в скрипте не было вовсе.
# Проход только ДОКЛАДЫВАЕТ: сам ничего не чинит и минуты Actions не жжёт.
watch_open_prs() {
  local rows num upd state stale_before report="" stamp
  stale_before=$(date -u -d "$PR_STALE_DAYS days ago" +%s 2>/dev/null) || return 0
  # Одним запросом на все PR: поштучный опрос mergeable занимал бы минуты
  # на каждом круге таймера.
  rows=$(gh pr list --state open --limit 100 --json number,updatedAt,mergeable,body \
    --jq '.[] | select(.body | test("AI-TASK: #[0-9]+|Closes #[0-9]+")) | "\(.number)\t\(.updatedAt)\t\(.mergeable)"' \
    2>/dev/null) || return 0
  while IFS=$'\t' read -r num upd state; do
    [ -z "$num" ] && continue
    if [ "$state" = "CONFLICTING" ]; then
      report+="  #$num — конфликт с $BASE_BRANCH, нужен ребейз"$'\n'
    elif [ "$(date -u -d "$upd" +%s 2>/dev/null || echo 9999999999)" -lt "$stale_before" ]; then
      report+="  #$num — без движения с ${upd%%T*}"$'\n'
    fi
  done <<< "$rows"
  [ -z "$report" ] && return 0
  log "Открытые AI-PR, требующие внимания:"$'\n'"$report"
  # Telegram — не чаще раза в сутки, иначе сводка придёт каждые 15 минут.
  stamp="$LOG_DIR/.pr-watch-$(date +%F)"
  [ -e "$stamp" ] && return 0
  : > "$stamp"
  tg "👁 AI dev loop ($(basename "$REPO_DIR")): открытые PR требуют внимания:"$'\n'"$report"
}

# ─── Режим github-app: помощники ────────────────────────────────────
issue_has_marker() {  # $1 = номер issue, $2 = маркер, $3 = unix-время поручения
  # Маркер ищем ТОЛЬКО в комментариях агента (не самого оркестратора) и
  # ТОЛЬКО в начале строки. Иначе инструктаж оркестратора, где сам текст
  # «NEEDS-PARTNER:»/«CANNOT-FIX-HERE:» упомянут по-русски, давал ложное
  # срабатывание — задача блокировалась через ~60 c после старта, ещё до
  # того как агент успевал ответить.
  # Логин подставляем через окружение: у `gh --jq` нет --arg (это не внешний
  # jq, а встроенный), и лишние слова уезжали в позиционные аргументы —
  # `gh issue view` падал с «accepts 1 arg(s), received 4», маркер не находился
  # НИКОГДА, и задача крутилась по кругу до таймаута APP_WAIT_MIN.
  # Вывод складываем в переменную, а не пайпим: `grep -q` закрывает пайп на
  # первом совпадении, gh получает SIGPIPE (141) и pipefail гасит успех.
  # $3 — как в claude_finished_since: смотрим только комментарии ПОСЛЕ
  # поручения. Без этого вердикт с прошлого круга срабатывал снова: задача,
  # вернувшаяся из-под blocked, на первой же итерации ожидания натыкалась на
  # свой же старый NEEDS-PARTNER и заводила дубль у партнёра (android#226 →
  # mahalla#217, а через 6 суток он же → mahalla#272), пока текущий прогон
  # агента ещё шёл.
  local bodies since="${3:-0}"
  bodies=$(SELF_LOGIN="${SELF_LOGIN:-}" gh issue view "$1" --json comments \
    --jq ".comments[]
          | select(.author.login != env.SELF_LOGIN)
          | select((.createdAt | fromdateiso8601) >= $since)
          | .body") || return 1
  printf '%s\n' "$bodies" | grep -qE "^[[:space:]]*$2"
}

find_task_pr() {  # $1 = номер issue → URL открытого PR по этой задаче
  local url
  url=$(gh pr list --state open \
    --search "\"AI-TASK: #$1\" in:body" \
    --json url --jq '.[0].url // empty')
  [ -n "$url" ] && { echo "$url"; return 0; }
  # Агент обязан ставить обе строки, но ставит не всегда: PR #315 в
  # mahalla-android получил только «Closes #314», из-за чего стал невидим
  # для цикла — тот считал, что PR не существует, и PR завис навсегда.
  gh pr list --state open \
    --search "\"Closes #$1\" in:body" \
    --json url --jq '.[0].url // empty'
}

pr_head_sha() { gh pr view "$1" --json headRefOid --jq .headRefOid; }

# GitHub считает mergeable лениво: первый запрос по «остывшему» PR отдаёт
# UNKNOWN и только запускает расчёт. Поэтому переспрашиваем.
pr_mergeable() {  # $1 = PR → MERGEABLE | CONFLICTING | UNKNOWN
  local i state
  for i in 1 2 3; do
    state=$(gh pr view "$1" --json mergeable --jq .mergeable 2>/dev/null || echo UNKNOWN)
    [ "$state" != "UNKNOWN" ] && { echo "$state"; return 0; }
    sleep 3
  done
  echo UNKNOWN
}

# Просим агента доработать PR и ждём новый коммит в той же ветке.
# Возвращает 0, если коммит появился. Логика ожидания — та же, что у
# дожима красного CI (github-app), плюс ветка для local-режима.
agent_rework() {  # $1 = PR, $2 = номер issue, $3 = текст поручения
  local old_sha asked_at deadline
  old_sha=$(pr_head_sha "$1")
  if [ "$DEV_MODE" = "local" ]; then
    run_claude "$3$BLOCK_HINT" 2>&1 | tee "$LOG_DIR/issue-$2-rework.log" \
      || log "⚠️ claude завершился с ошибкой, идём дальше"
    if [ -n "$PARTNER_REPO" ] && issue_is_blocked "$2"; then return 1; fi
    git push --force-with-lease || return 1
    [ "$(pr_head_sha "$1")" != "$old_sha" ]
    return $?
  fi
  gh pr comment "$1" --body "@claude $3$BLOCK_HINT"
  asked_at=$(date +%s)
  deadline=$(( asked_at + APP_WAIT_MIN * 60 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 60
    handle_partner_signal "$2" "$1" "$asked_at"
    [ "$(pr_head_sha "$1")" != "$old_sha" ] && return 0
    if claude_finished_since pr "$1" "$asked_at"; then
      log "@claude отчитался, но коммита нет."
      return 1
    fi
  done
  log "Ответ от @claude не пришёл за $APP_WAIT_MIN мин."
  return 1
}

# github-app: @claude закончил работу и написал итоговый комментарий
# (в теле — «Claude finished»). Смотрим только комментарии, появившиеся
# ПОСЛЕ поручения, иначе сработает вердикт с прошлого круга.
# Без этой проверки задача, по которой агент решил не открывать PR,
# висела в ожидании все APP_WAIT_MIN и возвращалась в очередь снова
# и снова (#237: ответ за 36 сек — ожидание 180 мин).
claude_finished_since() {  # $1 = issue|pr, $2 = номер/URL, $3 = unix-время
  local n
  n=$(gh "$1" view "$2" --json comments --jq \
        "[.comments[]
          | select(.author.login == \"claude\")
          | select((.createdAt | fromdateiso8601) >= $3)
          | select(.body | test(\"Claude finished\"))] | length" 2>/dev/null) || return 1
  [ "${n:-0}" -gt 0 ]
}

# Реакция на сигналы агента про партнёрский репозиторий (github-app).
# NEEDS-PARTNER → сервер сам заводит задачу у партнёра и блокирует эту.
# CANNOT-FIX-HERE (или NEEDS-PARTNER при включённой защите) → человеку.
# При срабатывании функция завершает весь скрипт.
handle_partner_signal() {  # $1 = номер issue, $2 = URL PR (может быть пустым), $3 = unix-время поручения
  [ -z "$PARTNER_REPO" ] && return 0
  local since="${3:-0}"
  if issue_has_marker "$1" "CANNOT-FIX-HERE:" "$since" \
     || { [ "$PINGPONG_GUARD" = true ] && issue_has_marker "$1" "NEEDS-PARTNER:" "$since"; }; then
    gh issue edit "$1" --add-label "$HUMAN_LABEL"
    [ -n "$2" ] && gh pr close "$2" --comment "🛑 Агент считает, что чинить нужно не здесь, а встречная блокировка запрещена (защита от пинг-понга) — задача передана человеку." || true
    tg "🛑 AI dev loop: #$1 «$TITLE» — агенты двух репо не договорились, где чинить. Нужен ты."
    log "Пинг-понг остановлен, задача у человека."
    exit 0
  fi
  if issue_has_marker "$1" "NEEDS-PARTNER:" "$since"; then
    local details new twin
    # Подстраховка от дубля: если задача с этим же ORIGIN у партнёра уже
    # заводилась — не создаём вторую, а переиспользуем её. Открытую ждём,
    # закрытую считаем уже починенной и идём работать дальше.
    twin=$(gh issue list -R "$PARTNER_REPO" --state all --limit 1 \
      --search "\"ORIGIN: $THIS_REPO#$1\" in:body sort:created-desc" \
      --json number,state --jq '.[0] | "\(.number) \(.state)"' 2>/dev/null || true)
    if [ -n "$twin" ]; then
      if [ "${twin#* }" = "CLOSED" ]; then
        log "У партнёра уже есть закрытая задача #${twin%% *} с этим ORIGIN — блокировку не ставлю."
        return 0
      fi
      gh issue comment "$1" --body "BLOCKED-BY: $PARTNER_REPO#${twin%% *}"
      gh issue edit "$1" --add-label blocked
      [ -n "$2" ] && gh pr close "$2" --comment "⏳ Причина на стороне $PARTNER_REPO — задача там уже заведена ранее. После починки эта задача автоматически вернётся в очередь." || true
      tg "⏳ AI dev loop: #$1 «$TITLE» заблокирована — ждёт $PARTNER_REPO#${twin%% *} (задача там уже была)."
      log "Задача #$1 ждёт существующую $PARTNER_REPO#${twin%% *}. Стоп."
      exit 0
    fi
    details=$(gh issue view "$1" --json comments \
      --jq "[.comments[] | select((.createdAt | fromdateiso8601) >= $since) | .body] | join(\"\n\")" \
      | grep -m1 -A20 'NEEDS-PARTNER:')
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

# Сначала возвращаем в очередь задачи, чей блокер в соседнем репо закрыт:
unblock_ready_issues

# Затем докладываем про открытые PR, которые зависли без внимания:
watch_open_prs

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
  ASSIGNED_AT=$(date +%s)
  VERDICT_NO_PR=false

  # Задача могла вернуться в очередь (сняли blocked, перезапустили юнит) уже
  # с готовым PR от прошлого прогона. Звать @claude второй раз — холостой
  # прогон Actions и лишние комментарии в issue ради того же результата,
  # поэтому сначала ищем существующий PR и только потом поручаем.
  PR_URL=$(find_task_pr "$NUM")

  if [ -n "$PR_URL" ]; then
    log "По задаче #$NUM уже открыт PR: $PR_URL — @claude не зову."
  else
    gh issue comment "$NUM" --body "@claude Реализуй задачу из этого issue.
Требования:
- следуй CLAUDE.md репозитория;
- где возможно, прогони сборку и тесты у себя перед пушем;
- открой pull request в ветку $BASE_BRANCH;
- в описании PR обязательно укажи две строки: «AI-TASK: #$NUM» и «Closes #$NUM».$BLOCK_HINT"

    log "Задача поручена @claude, жду появления PR (до $APP_WAIT_MIN мин)…"
    DEADLINE=$(( ASSIGNED_AT + APP_WAIT_MIN * 60 ))
    while [ "$(date +%s)" -lt "$DEADLINE" ]; do
      sleep 60
      handle_partner_signal "$NUM" "" "$ASSIGNED_AT"
      PR_URL=$(find_task_pr "$NUM")
      [ -n "$PR_URL" ] && break
      if claude_finished_since issue "$NUM" "$ASSIGNED_AT"; then
        VERDICT_NO_PR=true
        break
      fi
    done
  fi

  if [ -z "$PR_URL" ]; then
    gh issue edit "$NUM" --add-label "$HUMAN_LABEL"
    if [ "$VERDICT_NO_PR" = true ]; then
      log "@claude завершил работу без PR — задача уходит человеку."
      gh issue comment "$NUM" --body "🛑 @claude завершил работу и PR не открыл — нужен человек. Если задача уже сделана, закрой issue; если нет — переформулируй и сними метку \`$HUMAN_LABEL\` (ход работы: комментарии и вкладка Actions)."
      tg "🛑 AI dev loop: #$NUM «$TITLE» — @claude отработал, но PR не открыл. Нужен ты."
    else
      gh issue comment "$NUM" --body "🛑 @claude не открыл PR за $APP_WAIT_MIN минут — нужен человек (ход работы: комментарии и вкладка Actions)."
      tg "🛑 AI dev loop: #$NUM «$TITLE» — PR от @claude не появился за $APP_WAIT_MIN мин. Нужен ты."
    fi
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
    ASKED_AT=$(date +%s)
    DEADLINE=$(( ASKED_AT + APP_WAIT_MIN * 60 ))
    FIXED=false
    while [ "$(date +%s)" -lt "$DEADLINE" ]; do
      sleep 60
      handle_partner_signal "$NUM" "$PR_URL" "$ASKED_AT"
      if [ "$(pr_head_sha "$PR_URL")" != "$OLD_SHA" ]; then FIXED=true; break; fi
      # Агент отчитался, но коммита нет — сам он уже не запушит.
      if claude_finished_since pr "$PR_URL" "$ASKED_AT"; then
        log "@claude завершил работу, но коммит не запушил — передаю человеку."
        break
      fi
    done
    if [ "$FIXED" != true ]; then
      if [ "$(date +%s)" -ge "$DEADLINE" ]; then
        log "Фикс от @claude не пришёл за $APP_WAIT_MIN мин — передаю человеку."
      fi
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

# ═══ 4b. PR ready → мержабельность → цикл ревью ════════════════════
gh pr ready "$PR_URL" 2>/dev/null || true   # PR от App может быть уже не draft

# Раньше цикл на mergeable не смотрел вовсе: PR, разошедшийся с $BASE_BRANCH,
# уходил «ждать человека» как здоровый и оставался там навсегда.
MERGE_STATE=$(pr_mergeable "$PR_URL")
if [ "$MERGE_STATE" = "CONFLICTING" ]; then
  log "PR конфликтует с $BASE_BRANCH — прошу агента подтянуть ветку."
  if agent_rework "$PR_URL" "$NUM" "PR конфликтует с веткой \`$BASE_BRANCH\`. Влей свежий \`$BASE_BRANCH\` в ветку PR, разреши конфликты, ничего из изменений PR не потеряв, и запушь в ту же ветку. Логику задачи при этом не меняй."; then
    MERGE_STATE=$(pr_mergeable "$PR_URL")
  fi
  if [ "$MERGE_STATE" = "CONFLICTING" ]; then
    gh issue edit "$NUM" --add-label "$HUMAN_LABEL"
    gh issue comment "$NUM" --body "🛑 PR конфликтует с \`$BASE_BRANCH\`, автоматически разрешить не вышло — нужен человек: $PR_URL"
    tg "🛑 AI dev loop: #$NUM «$TITLE» — PR конфликтует с $BASE_BRANCH. Нужен ты: $PR_URL"
    log "Конфликт не разрешён. Стоп."
    exit 0
  fi
fi

# Дожим ревью. Раньше вердикт не читался нигде, кроме ветки авто-merge:
# и APPROVE, и REQUEST_CHANGES вели в один и тот же конец итерации, так что
# замечания ревьюера не получал никто и PR копились.
REVIEW_ROUND=1
REVIEW_OK=false
REWORK_WHY="авто-ревью осталось при \`REQUEST_CHANGES\` после $MAX_REVIEW_ROUNDS круга доработки"
while :; do
  REVIEW=$(gh pr diff "$PR_URL" | \
    env -u TELEGRAM_BOT_TOKEN -u TELEGRAM_CHAT_ID claude "${CLAUDE_ARGS[@]}" \
    "Ты строгий, но честный код-ревьюер. На stdin — дифф pull request'а.
Проверь: безопасность (секреты, инъекции, права), корректность логики,
обработку ошибок, качество кода. Пиши кратко и по делу, по-русски.

ПРЕЖДЕ ЧЕМ НАЗВАТЬ ЧТО-ТО БЛОКЕРОМ — проверь себя:
- CI на этом PR уже зелёный: сборка и тесты прошли. Поэтому замечание вида
  «это не скомпилируется» почти наверняка твоя ошибка — перепроверь по коду
  или не пиши его вовсе;
- дифф показан относительно базы ветки, а НЕ результата мержа. Прежде чем
  писать про порядок строк, дубли или «ветка отстала», проверь фактом:
  \`git merge-tree --write-tree origin/$BASE_BRANCH <ветка PR>\`;
- замечание без конкретного файла и строки — не замечание.
Ложный блокер дороже пропущенного: по нему будет переписан рабочий код.

САМОЙ ПОСЛЕДНЕЙ строкой выведи ровно одно из двух:
VERDICT: APPROVE
VERDICT: REQUEST_CHANGES")

  gh pr comment "$PR_URL" --body "## 🤖 Авто-ревью (круг $REVIEW_ROUND из $MAX_REVIEW_ROUNDS)

$REVIEW"

  if echo "$REVIEW" | grep -q "VERDICT: APPROVE"; then
    REVIEW_OK=true
    log "Ревью пройдено на круге $REVIEW_ROUND ✅"
    break
  fi
  if [ "$REVIEW_ROUND" -ge "$MAX_REVIEW_ROUNDS" ]; then
    log "Ревью не пройдено за $MAX_REVIEW_ROUNDS круга — передаю человеку."
    break
  fi

  log "Ревью вернуло REQUEST_CHANGES (круг $REVIEW_ROUND) — отдаю замечания агенту."
  if ! agent_rework "$PR_URL" "$NUM" "Авто-ревью вернуло \`REQUEST_CHANGES\` по этому PR (круг $REVIEW_ROUND из $MAX_REVIEW_ROUNDS). Сами замечания — в комментарии выше.

Не бросайся исправлять всё подряд: этот ревьюер ошибается примерно в трети
блокеров, и всегда одинаково — судит по диффу относительно базы ветки,
игнорируя зелёный CI и результат мержа.
По каждому замечанию сначала установи факт: по коду, по статусу CI и по
\`git merge-tree --write-tree origin/$BASE_BRANCH HEAD\`. Затем:
- подтверждённое — исправь и запушь коммит в эту же ветку;
- ошибочное — код НЕ трогай, ответь отдельным комментарием в PR, что именно
  неверно и чем это опровергается.
Если подтверждённых замечаний не нашлось вовсе — не коммить ничего, только ответь."; then
    REWORK_WHY="агент не доработал PR по замечаниям ревью"
    log "Доработки по ревью не случилось — передаю человеку."
    break
  fi

  # Доработка могла сломать сборку — до следующего круга ревью перепроверяем.
  sleep "$CI_START_WAIT"
  if ! gh pr checks "$PR_URL" --watch; then
    REWORK_WHY="после доработки по замечаниям ревью CI стал красным"
    log "После доработки CI покраснел — передаю человеку."
    break
  fi
  REVIEW_ROUND=$(( REVIEW_ROUND + 1 ))
done

# ═══ 5. Merge ═══════════════════════════════════════════════════════
if [ "$REVIEW_OK" != true ]; then
  gh issue edit "$NUM" --add-label "$HUMAN_LABEL"
  gh issue comment "$NUM" --body "🛑 Нужен человек: $REWORK_WHY. PR: $PR_URL"
  tg "🛑 AI dev loop: #$NUM «$TITLE» — $REWORK_WHY. Нужен ты: $PR_URL"
  log "Стоп: $REWORK_WHY."
  exit 0
fi

if [ "$AUTO_MERGE" = "true" ]; then
  gh pr merge "$PR_URL" --squash --auto
  gh issue comment "$NUM" --body "✅ Ревью пройдено, PR поставлен на авто-merge: $PR_URL"
  tg "✅ AI dev loop: #$NUM «$TITLE» готово и уходит в авто-merge: $PR_URL"
  log "Авто-merge включён для $PR_URL"
else
  gh issue comment "$NUM" --body "👀 PR готов и ждёт вашего решения: $PR_URL"
  tg "👀 AI dev loop: #$NUM «$TITLE» — PR готов, глянь, когда будет минутка: $PR_URL"
  log "PR ждёт человека: $PR_URL"
fi

gh issue edit "$NUM" --remove-label "$TASK_LABEL"
log "Итерация завершена. 🎉"
