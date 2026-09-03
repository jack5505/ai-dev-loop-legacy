# ЗАДАНИЕ ДЛЯ CLAUDE CODE: развернуть AI dev loop на этом сервере
# (версия для ДВУХ репозиториев: backend + android)

Ты — Claude Code, запущенный на Linux-сервере. В этой папке лежит всё
необходимое. Цель — развернуть автономный цикл разработки для ДВУХ
репозиториев проекта (backend и android) и довести оба до первого
успешного тестового прогона.

## Что за система (для понимания)

Проект человека живёт в двух репозиториях: backend и android.
Для каждого крутится СВОЙ независимый цикл — общий у них только
скрипт-оркестратор и Claude-подписка.

Оркестратор `orchestrator-ci.sh` по systemd-таймеру раз в 15 минут:
берёт следующий GitHub issue с меткой `ai-task` → реализует задачу
через Claude Code (headless) в ветке `ai/issue-N` → пушит draft-PR →
ждёт CI GitHub Actions → красный CI чинит (максимум 3 попытки, дальше
метка `needs-human`) → зелёный CI: PR помечается ready + авто-ревью →
уведомление человеку в Telegram. Сервер лёгкий: сборку и тесты делает
GitHub Actions, поэтому JDK / Android SDK / эмулятор здесь НЕ нужны.

## Как связаны два репозитория

Если во время работы агент видит, что причина ошибки на стороне
ДРУГОГО репозитория (классика: android-тесты падают из-за
backend-API), он: заводит issue с меткой `ai-task` в том репозитории,
ставит на свою задачу метку `blocked` и оставляет комментарий-маркер
`BLOCKED-BY: owner/repo#N`. Заблокированные задачи из очереди
исключаются. Каждый круг оркестратор проверяет блокеры: как только
задача в соседнем репо закрыта (её PR смержен) — метка `blocked`
снимается, и исходная задача автоматически возвращается в очередь на
перепроверку. Для этого в env-файлах перекрёстно заполняется
PARTNER_REPO (шаг 4).

Встроенные защиты. Первая — от prompt injection: в очередь попадают
только issues от доверенных авторов (по умолчанию — владелец
gh-токена; расширяется через ALLOWED_AUTHORS в env), поэтому чужой
текст из публичного репозитория агенту в промпт не попадает. Вторая —
от пинг-понга: задача, пришедшая из партнёрского репо (маркер ORIGIN
в описании) или уже блокировавшаяся дважды, встречную блокировку
создать не может; если агент считает, что чинить нужно не у него,
такая пара задач уходит человеку с меткой needs-human. Обе защиты
зашиты в оркестратор, а не только в промпт.

## Файлы в пакете

- `orchestrator-ci.sh` — оркестратор (один на всех) → `/opt/ai-dev/`
- `ai-dev@.service`, `ai-dev@.timer` — шаблонные systemd-юниты;
  инстанс `ai-dev@backend` читает `/etc/ai-dev-backend.env`,
  инстанс `ai-dev@android` — `/etc/ai-dev-android.env`
- `ai-dev.env.example` — шаблон конфига (копируется дважды)
- `ci-android.yml` — workflow → в android-репо как `.github/workflows/ci.yml`
- `ci-backend.yml` — workflow-заготовка → в backend-репо как
  `.github/workflows/ci.yml` (требует заполнения под стек!)
- `CLAUDE-android.md`, `CLAUDE-backend.md` — правила для агента →
  в корень соответствующего репо под именем `CLAUDE.md`
- `TELEGRAM.md` — инструкция по уведомлениям (для человека)

## Твои правила на время развёртывания

1. Перед КАЖДОЙ командой с sudo — объясни в одну строку, что она
   делает, и жди подтверждения человека.
2. Секреты (вход в GitHub, токен Claude, Telegram-токен) — НИКОГДА не
   проси прислать тебе в чат. Давай человеку готовую команду, он
   выполняет её сам и говорит «готово». Содержимое env-файлов не
   выводи на экран.
3. Не root: проверь `whoami` — если root, остановись и попроси
   человека перезайти обычным пользователем.
4. Что-то не получается — не отключай защиты и не изобретай обходы.
   Остановись, покажи ошибку, спроси человека.
5. Иди строго по шагам, после каждого коротко отчитывайся.

## Шаг 0. Проверка окружения

Проверь и покажи таблицей: ОС (`lsb_release -a`), память (`free -h`),
диск (`df -h /`), версии `git`, `jq`, `curl`, `node` (нужен 20+),
`gh`, `claude`. Чего не хватает — установи (`sudo apt install ...`,
Node при необходимости через nodesource). Если RAM < 4 ГБ и свопа
нет — предложи создать своп 2 ГБ и, после подтверждения, создай:

```bash
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

## Шаг 1. Доступы

- GitHub: `gh auth status`. Если не залогинен — попроси человека
  выполнить `gh auth login` самому (нужны права repo на ОБА
  репозитория), дождись «готово», перепроверь.
- Claude: спроси человека, чем он платит — подписка (OAuth) или
  API-ключ. Для подписки дай ему команду `claude setup-token`
  (выполняется на машине с браузером; токен он впишет в конфиги на
  шаге 4 сам). Сам токен тебе не нужен.

## Шаг 2. Репозитории (повторяется для обоих)

Спроси у человека два URL: backend-репозиторий и android-репозиторий,
и куда клонировать (по умолчанию `~/backend` и `~/android`).

Для КАЖДОГО из двух репозиториев:

1. Клонируй (если ещё не склонирован).
2. Создай метки (ошибку «already exists» игнорируй):

```bash
gh label create ai-task     --color 1D76DB --description "Очередь AI-агента"
gh label create needs-human --color D93F0B --description "AI сдался, нужен человек"
gh label create emulator    --color FBCA04 --description "Гонять тесты на эмуляторе"
gh label create blocked     --color 5319E7 --description "Ждёт починки в другом репозитории"
```

   (метка `emulator` реально используется только в android-репо,
   но пусть будет в обоих для единообразия)
3. Скопируй файлы:
   - android-репо: `ci-android.yml` → `.github/workflows/ci.yml`,
     `CLAUDE-android.md` → `CLAUDE.md` в корень;
   - backend-репо: `ci-backend.yml` → `.github/workflows/ci.yml`,
     `CLAUDE-backend.md` → `CLAUDE.md` в корень.
   Если CLAUDE.md в репо уже есть — не перезаписывай, покажи различия.
4. Пройдись по TODO вместе с человеком. Backend — Java/Spring:
   `ci-backend.yml` уже содержит рабочие шаги (JDK 17, автоопределение
   Gradle/Maven). Проверь версию Java проекта (если 21 — поправь в
   workflow) и что команда сборки реально проходит. Если в репо уже
   есть работающий CI-workflow — используй его, ci-backend.yml не
   добавляй.
5. Закоммить и, после подтверждения человека, запушь в основную ветку.
6. Напомни человеку включить в настройках репозитория на GitHub
   (в браузере, не тобой): Settings → General → Allow auto-merge;
   Settings → Branches → protection rule на main.

## Шаг 3. Установка оркестратора

```bash
sudo mkdir -p /opt/ai-dev
sudo cp orchestrator-ci.sh /opt/ai-dev/
sudo chmod +x /opt/ai-dev/orchestrator-ci.sh
sudo chown $(whoami): /opt/ai-dev/orchestrator-ci.sh
```

## Шаг 4. Конфиги — два файла

```bash
sudo cp ai-dev.env.example /etc/ai-dev-backend.env
sudo cp ai-dev.env.example /etc/ai-dev-android.env
sudo chmod 600 /etc/ai-dev-backend.env /etc/ai-dev-android.env
```

Подставь в каждый файл его `REPO_DIR` (backend → `~/backend`,
android → `~/android`; можешь сам через sudo sed, пути абсолютные)
и `PARTNER_REPO` перекрёстно: в backend-конфиг — `owner/имя-android-репо`,
в android-конфиг — `owner/имя-backend-репо` (owner/имя возьми из URL,
которые дал человек). `ALLOWED_AUTHORS` оставь пустым — тогда очередь
принимает только issues владельца gh-токена.
Затем попроси человека самостоятельно открыть по очереди
`sudoedit /etc/ai-dev-backend.env` и `sudoedit /etc/ai-dev-android.env`
и вписать В ОБА: `CLAUDE_CODE_OAUTH_TOKEN` (или `ANTHROPIC_API_KEY`)
и, по желанию, Telegram-переменные (TELEGRAM.md). Токены в обоих
файлах одинаковые. Дождись «готово». Проверить заполненность, не
раскрывая значений:

```bash
sudo grep -E '^(CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY|TELEGRAM|REPO_DIR)' /etc/ai-dev-backend.env /etc/ai-dev-android.env | sed 's/=.*/=***/'
```

## Шаг 5. systemd

В `ai-dev@.service` замени `REPLACE_ME_USER` на текущего пользователя
(`whoami`), затем:

```bash
sudo cp ai-dev@.service ai-dev@.timer /etc/systemd/system/
sudo systemctl daemon-reload
```

Таймеры пока НЕ включай.

## Шаг 6. Тестовые прогоны (по одному на репозиторий, до таймеров)

Сначала backend, потом android — по очереди, не параллельно, чтобы
человеку было проще следить.

В репозитории (например, backend):

```bash
cd ~/backend
gh issue create --label ai-task \
  --title "Тест цикла: добавить файл HELLO.md" \
  --body "Создай в корне репозитория файл HELLO.md с текстом 'AI dev loop работает'. Больше ничего не меняй."

sudo systemctl start ai-dev@backend.service
journalctl -u ai-dev@backend.service -f
```

Критерии успеха: в issue комментарий «взял в работу» → появился PR →
CI отработал → комментарий с авто-ревью → PR ready → (если настроен
Telegram) пришёл пинг. Покажи человеку ссылку на PR. Если что-то
упало — разбери лог, объясни причину, предложи фикс.

Затем то же самое для android (`ai-dev@android.service`).

## Шаг 7. Включить вечные циклы

Только после того, как человек посмотрел ОБА тестовых PR и сказал «да»:

```bash
sudo systemctl enable --now ai-dev@backend.timer ai-dev@android.timer
systemctl list-timers 'ai-dev@*'
```

## Финальный чек-лист (покажи человеку заполненным)

- [ ] Окружение: node 20+, gh, claude, своп при RAM < 4 ГБ
- [ ] gh auth: залогинен, видит оба репозитория
- [ ] backend: склонирован, метки, CI (Java/Spring) зелёный на main,
      CLAUDE.md в main
- [ ] android: склонирован, метки, ci.yml + CLAUDE.md в main
- [ ] /opt/ai-dev/orchestrator-ci.sh установлен, исполняемый
- [ ] /etc/ai-dev-backend.env и /etc/ai-dev-android.env: 600, токены
      заполнены (значения не раскрывать), PARTNER_REPO перекрёстно
- [ ] systemd: шаблонные юниты установлены
- [ ] Тестовые прогоны: PR в обоих репо созданы и проверены человеком
- [ ] Оба таймера включены

После этого объясни человеку в нескольких предложениях, как этим
жить: задачи закидывать в НУЖНЫЙ репозиторий с меткой `ai-task`
(`gh issue create --label ai-task ...` или через сайт GitHub); для
связанных фич сначала issue в backend, а после его merge — issue в
android со ссылкой на новый API-контракт; смотреть работу —
`journalctl -u 'ai-dev@*' -f`; Telegram сам позовёт, когда нужна
помощь.
