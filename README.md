# Healthside — бэкенд

Privacy-first, self-hosted сервис для хранения и разбора медицинских анализов (PDF/фото). Пользователь загружает свои анализы, сервис один раз разбирает каждый файл в структурированные данные (биомаркеры) через Claude API и по запросу собирает целостный чекап по всей истории.

## Стек

- **Vapor 4** (Swift) + **Fluent** — веб-фреймворк и ORM
- **PostgreSQL** — основная БД
- **JWT + Bcrypt** — авторизация (access/refresh токены, хеш паролей)
- **Vapor Queues + Redis** — фоновая обработка (извлечение данных, чекап)
- **Claude API** (`Sources/Healthside/LLM`) — провайдер-агностичный интерфейс для разбора документов
- **Docker Compose** — локальный запуск и деплой

Подробности и обоснование выбора — в справочнике «Deployment» вики `HealthSideDocs`.

## Быстрый старт (локально)

1. Скопировать `.env.example` в `.env` и заполнить `LLM_API_KEY` (ключ Claude API). `.env` в `.gitignore` — коммитить нельзя.
   ```bash
   cp .env.example .env
   ```
2. Поднять Postgres и Redis:
   ```bash
   docker compose up -d db redis
   ```
3. Собрать проект:
   ```bash
   swift build
   ```
4. Накатить миграции:
   ```bash
   swift run Healthside migrate --yes
   ```
5. Запустить сервер:
   ```bash
   swift run Healthside serve
   ```

Сервер поднимется на `http://localhost:8080`. Без `REDIS_URL` очередь не включается — загрузка файлов работает, но разбор остаётся `pending` (есть ручной фолбэк `POST /documents/:id/extract`).

## Тесты

```bash
swift test
```

Гоняются против отдельной тестовой БД (`DATABASE_NAME_TEST`, по умолчанию `vapor_test`), не трогают dev-схему.

## Запуск целиком через Docker

```bash
docker compose up -d db redis
docker compose run migrate
docker compose up -d app worker
```

- `app` — HTTP API (порт `8080`)
- `worker` — тот же образ в режиме обработчика очереди (`ExtractionJob`/чекап)
- `migrate` / `revert` — одноразовые команды миграций
- `adminer` (опционально, `--profile tools`) — веб-интерфейс к БД на `http://localhost:8081`

## API-документация

- Swagger UI: `http://localhost:8080/docs/`
- OpenAPI-спека: [`Public/openapi.yaml`](Public/openapi.yaml)
- Полная карта эндпоинтов: справочник `API` в вики `HealthSideDocs`

## Структура

```
Sources/Healthside/
  Controllers/   — HTTP-хендлеры (Auth, LabResult, Document, Checkup, User)
  Models/        — Fluent-модели
  Migrations/    — версионированная схема БД
  Services/      — бизнес-логика (извлечение, деидентификация, сборка чекапа)
  LLM/           — интеграция с Claude API (промпты, схема, провайдер)
  Jobs/          — фоновые задачи очереди
  Middleware/    — rate limiting, security headers
  Storage/       — работа с файлами (типы, проверка изображений)
  Authentication/— JWT-аутентификатор
```

## Переменные окружения

См. [`.env.example`](.env.example) — полный список с комментариями. Ключевые:

| Переменная | Назначение |
|---|---|
| `JWT_SECRET` | подпись access-токенов (обязателен в production) |
| `LLM_API_KEY` | ключ Claude API для извлечения/чекапа |
| `DATABASE_*` | подключение к PostgreSQL |
| `REDIS_URL` | очередь фоновых задач (опционально локально) |
| `STORAGE_PATH` | путь к локальному хранилищу файлов анализов |

Секреты — только через окружение, никогда не в коде и не в репозитории.

## Документация проекта

Полная документация (архитектура, поток данных, безопасность/приватность, комплаенс, промпты, мобильная часть) — в отдельном Obsidian-вики `HealthSideDocs`, папка `Backend/`.
