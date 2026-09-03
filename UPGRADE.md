# ЗАДАНИЕ ДЛЯ CLAUDE CODE: включить режим github-app для android

Система ai-dev loop уже развёрнута и работает (backend — режим local).
Твоя цель: обновить оркестратор и перевести ТОЛЬКО android-репозиторий
(jack5505/mahalla-android, публичный) в режим `github-app` — чтобы код
для android писал @claude на GitHub Actions, а сервер остался
дирижёром. Backend не трогать. Контекст и устройство режима — в
APP-MODE.md в этой же папке (прочитай его первым).

## Правила (те же, что при развёртывании)

1. Перед КАЖДОЙ sudo-командой объясни в одну строку, что она делает,
   и жди подтверждения человека.
2. Секреты не проси в чат и не выводи на экран (содержимое
   /etc/ai-dev-*.env не показывать).
3. Что-то не получается — остановись, покажи ошибку, спроси.
4. После каждого шага — короткий отчёт.

## Шаг 0. Пауза таймеров на время обновления

```bash
sudo systemctl stop ai-dev@backend.timer ai-dev@android.timer
systemctl list-timers 'ai-dev@*'   # убедись, что пусто
```

Если сейчас идёт активная итерация (`systemctl is-active 'ai-dev@*'`) —
дождись её окончания.

## Шаг 1. Обновить оркестратор

```bash
sudo cp orchestrator-ci.sh /opt/ai-dev/orchestrator-ci.sh
sudo chmod +x /opt/ai-dev/orchestrator-ci.sh
bash -n /opt/ai-dev/orchestrator-ci.sh && echo OK
```

## Шаг 2. Workflow @claude в android-репо (КРИТИЧНО для публичного)

1. Посмотри `.github/workflows/` в android-репозитории: есть ли уже
   workflow с anthropics/claude-code-action.
2. Если есть — приведи его к виду из `claude-android.yml` этой папки:
   главное, чтобы в job стояло условие
   `github.actor == 'jack5505' && contains(github.event.comment.body, '@claude')`.
   Если нет — скопируй `claude-android.yml` как
   `.github/workflows/claude.yml`. Двух workflow на @claude быть не
   должно — оставь один.
3. Закоммить и запушь в main (с подтверждения человека).

Объясни человеку одной фразой, зачем это условие: репозиторий
публичный, без него любой прохожий сможет командовать агентом.

## Шаг 3. Секрет подписки в android-репо

Токен уже лежит в /etc/ai-dev-android.env — перекладываем его в
секрет репозитория, не показывая на экране:

```bash
sudo bash -c 'source /etc/ai-dev-android.env && printf %s "$CLAUDE_CODE_OAUTH_TOKEN" | gh secret set CLAUDE_CODE_OAUTH_TOKEN -R jack5505/mahalla-android'
gh secret list -R jack5505/mahalla-android   # проверь, что появился
```

(Если переменной в env нет — попроси человека выполнить
`gh secret set CLAUDE_CODE_OAUTH_TOKEN -R jack5505/mahalla-android`
самому и вставить токен из `claude setup-token`.)

## Шаг 4. Режим github-app в конфиге android

```bash
sudo tee -a /etc/ai-dev-android.env > /dev/null << 'EOF'
DEV_MODE=github-app
APP_WAIT_MIN=45
EOF
sudo grep -E '^(DEV_MODE|APP_WAIT_MIN)' /etc/ai-dev-android.env
```

Backend-конфиг НЕ трогать (там остаётся local по умолчанию).

## Шаг 5. CLAUDE.md android-репо: разрешить сборки

В android-репозитории найди в CLAUDE.md раздел с запретом запускать
gradle («Ограничение сервера» или похожий) и замени его на:

```markdown
## Окружение
- Ты работаешь на CI-раннере GitHub: JDK и Android SDK доступны,
  ./gradlew запускать МОЖНО и нужно (сборка, тесты, lint) до пуша.
```

Если такого раздела нет — просто добавь этот блок. Закоммить, запушь.

## Шаг 6. Боевая проверка на задаче #39

В очереди android уже висит issue #39 (lint). Прогони одну итерацию
вручную и наблюдай:

```bash
sudo systemctl start ai-dev@android.service
journalctl -u ai-dev@android.service -f
```

Критерии успеха по порядку:
1. В issue #39 появился комментарий оркестратора с «@claude Реализуй…».
2. Во вкладке Actions android-репо стартовал workflow Claude
   (проверь: `gh run list -R jack5505/mahalla-android --limit 3`).
3. @claude открыл PR с «AI-TASK: #39» в описании (может занять
   10–30 минут — жди, лог сервера будет молчать, это норма).
4. Оркестратор нашёл PR («PR от @claude: …» в journalctl) и ждёт CI.

Дальше цикл сам: CI → фиксы → ревью → пинг в Telegram. Дожидаться
полного конца не обязательно — как только пункт 4 случился, механика
доказана.

Если workflow не стартовал: проверь, что комментарий написан от
jack5505, что условие actor в workflow совпадает с этим логином, и
что секрет на месте.

## Шаг 7. Вернуть таймеры

```bash
sudo systemctl start ai-dev@backend.timer ai-dev@android.timer
systemctl list-timers 'ai-dev@*'
```

## Финальный отчёт человеку

Покажи чек-лист: оркестратор обновлён; workflow с actor-защитой в
main; секрет установлен; DEV_MODE=github-app только у android;
CLAUDE.md разрешает сборки на раннере; issue #39 — @claude отреагировал
и открыл PR (ссылка); таймеры снова включены. Плюс напомни: ход
мышления android-агента теперь виден в комментариях PR и вкладке
Actions, а не в journalctl.
