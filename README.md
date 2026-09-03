# AI dev loop (legacy, bash)

Автономный цикл разработки на bash: сервер-«дирижёр» берёт GitHub-issue с
меткой `ai-task`, реализует задачу через **Claude Code**, открывает draft-PR,
дожидается GitHub Actions, чинит красный CI (до 3 попыток) и пингует человека
в Telegram. Сборка и тесты выполняются в GitHub Actions, поэтому серверу
достаточно ~2 ГБ RAM — ни JDK, ни Android SDK, ни эмулятор на нём не нужны.

> Это «legacy»-реализация на shell. Переписанная на Python версия живёт
> в отдельном репозитории.

## Как это работает

```
        ┌─────────── systemd timer (каждые 15 мин, на репозиторий) ───────────┐
        ▼                                                                       │
  orchestrator-ci.sh
        │  1. берёт следующий issue с меткой `ai-task` (только доверенные авторы)
        │  2. создаёт ветку ai/issue-N, реализует задачу через Claude Code
        │  3. push → draft-PR
        │  4. ждёт CI (gh pr checks --watch)
        │        ├─ красный → отдаёт лог Claude, чинит (до MAX_ITERATIONS)
        │        └─ зелёный → PR помечается ready + авто-ревью
        │  5. уведомление человеку в Telegram (когда нужен человек)
        └──────────────────────────────────────────────────────────────────────
```

Один оркестратор обслуживает **несколько репозиториев** — у каждого свой
инстанс systemd (`ai-dev@backend`, `ai-dev@android`) и свой env-файл. Циклы
разных репозиториев не наслаиваются (flock + `OnUnitInactiveSec`).

### Два режима (`DEV_MODE`)

| Режим | Кто пишет код | Для чего |
|-------|---------------|----------|
| `local` | Claude Code на самом сервере | приватный backend (~400 МБ RAM) |
| `github-app` | `@claude` на раннерах GitHub Actions | публичный репозиторий (сборка/lint прямо на раннере) |

### Встроенные защиты

- **От prompt injection** — в очередь попадают только issues от доверенных
  авторов (`ALLOWED_AUTHORS`, по умолчанию — владелец gh-токена).
- **От пинг-понга** — межрепозиторные блокировки (`BLOCKED-BY`, `PARTNER_REPO`)
  с защитой от встречных блокировок; спорные пары уходят человеку (`needs-human`).
- **Секреты вне промпта** — Telegram-токен вычищается из окружения перед
  каждым запуском Claude (`env -u ...`).

## Состав пакета

| Файл | Назначение | Куда ставится |
|------|-----------|---------------|
| `orchestrator-ci.sh` | Оркестратор (ядро цикла) | `/opt/ai-dev/` |
| `ai-dev@.service` | Шаблонный systemd-юнит (oneshot) | `/etc/systemd/system/` |
| `ai-dev@.timer` | Таймер (каждые 15 мин после завершения) | `/etc/systemd/system/` |
| `ai-dev.env.example` | Шаблон конфига (права **600**) | `/etc/ai-dev-<инстанс>.env` |
| `ci-backend.yml` | CI для backend (Java/Spring) | `.github/workflows/ci.yml` backend-репо |
| `ci-android.yml` | CI для android (+ эмулятор по метке) | `.github/workflows/ci.yml` android-репо |
| `claude-android.yml` | Workflow `@claude` c actor-защитой | `.github/workflows/claude.yml` android-репо |
| `CLAUDE-backend.md` | Правила агента для backend | `CLAUDE.md` в корень backend-репо |
| `CLAUDE-android.md` | Правила агента для android | `CLAUDE.md` в корень android-репо |

## Документация

- **[DEPLOY.md](DEPLOY.md)** — полное развёртывание с нуля (два репозитория: backend + android).
- **[APP-MODE.md](APP-MODE.md)** — включение режима `github-app` (код пишет `@claude` на GitHub Actions).
- **[UPGRADE.md](UPGRADE.md)** — пошаговое обновление действующей установки под режим `github-app`.
- **[TELEGRAM.md](TELEGRAM.md)** — настройка уведомлений в Telegram.

## Быстрый старт

Подробности — в [DEPLOY.md](DEPLOY.md). Коротко:

```bash
# 1. Оркестратор
sudo mkdir -p /opt/ai-dev
sudo cp orchestrator-ci.sh /opt/ai-dev/
sudo chmod +x /opt/ai-dev/orchestrator-ci.sh

# 2. Конфиг (по файлу на репозиторий), права строго 600
sudo cp ai-dev.env.example /etc/ai-dev-backend.env
sudo chmod 600 /etc/ai-dev-backend.env
sudoedit /etc/ai-dev-backend.env        # REPO_DIR, PARTNER_REPO, токен Claude

# 3. systemd (в ai-dev@.service заменить REPLACE_ME_USER на своего пользователя)
sudo cp ai-dev@.service ai-dev@.timer /etc/systemd/system/
sudo systemctl daemon-reload

# 4. Тестовый прогон одной итерации
gh issue create --label ai-task --title "Тест цикла" --body "Создай HELLO.md"
sudo systemctl start ai-dev@backend.service
journalctl -u ai-dev@backend.service -f

# 5. Вечный цикл
sudo systemctl enable --now ai-dev@backend.timer
```

## Требования

- Linux с systemd, ~2 ГБ RAM (при меньшем — своп).
- `git`, `jq`, `curl`, `node` 20+, [`gh`](https://cli.github.com/), [`claude`](https://docs.claude.com/claude-code) (Claude Code).
- Аккаунт GitHub с правами `repo` + `workflow` на управляемые репозитории.
- Подписка Claude Pro/Max (`claude setup-token`) **или** `ANTHROPIC_API_KEY`.

## Безопасность

- Секреты живут только в `/etc/ai-dev-*.env` (права **600**) — не в коде и не в issues.
- В очередь берутся issues только доверенных авторов (`ALLOWED_AUTHORS`).
- Для публичного репозитория в workflow `@claude` обязательна проверка
  `github.actor` — иначе командовать агентом сможет любой (см. `claude-android.yml`).
