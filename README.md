# Healthside backend

Self-hosted API for storing and parsing medical lab results (PDF/photo). A user uploads a file, the app parses it once into structured biomarker data via the Claude API, and serves a cached checkup report built from the full history.

## Stack

- Vapor 4 (Swift) + Fluent — web framework and ORM
- PostgreSQL
- JWT + Bcrypt — access/refresh tokens, password hashing
- Vapor Queues + Redis — background extraction/checkup jobs
- Claude API (`Sources/Healthside/LLM`) — document parsing, behind a provider-agnostic interface
- Docker / Docker Compose

## Local development

Requires Swift 6.3+ and Docker (for Postgres/Redis).

```bash
cp .env.example .env        # fill in LLM_API_KEY
docker compose up -d db redis
swift build
swift run Healthside migrate --yes
swift run Healthside serve
```

The server listens on `http://localhost:8080`. `swift run`/`swift build` pick up `.env` automatically (Vapor's `DotEnv`).

Without `REDIS_URL` the queue isn't configured: uploads still succeed but stay `pending`. Use `POST /documents/:id/extract` to parse manually.

## Docker

Every service (`app`, `worker`, `migrate`, `revert`) builds from the same `Dockerfile` and shares the `healthside:latest` image.

```bash
docker compose build
docker compose up -d db redis
docker compose run --rm migrate
docker compose up -d app worker
```

- `app` — HTTP API, port 8080
- `worker` — same image running `queues` (consumes `ExtractionJob`, checkup jobs)
- `migrate` / `revert` — one-shot migration commands (`replicas: 0`, only run via `docker compose run`)
- `adminer` — DB UI, disabled by default: `docker compose --profile tools up -d adminer` → `http://localhost:8081`

`docker-compose.yml` reads `JWT_SECRET` and `LLM_API_KEY` from the shell/`.env` file at the project root (`${VAR:-}`) — both are empty by default and the app refuses to start with a missing `JWT_SECRET` in production.

Stop everything: `docker compose down` (add `-v` to drop the `db_data` volume).

## Tests

```bash
swift test
```

Runs against a separate database (`DATABASE_NAME_TEST`, defaults to `vapor_test`) so it never touches the dev schema. Postgres doesn't create this database for you — create it once:

```bash
docker compose exec db createdb -U vapor_username vapor_test
```

## API docs

- Swagger UI: `http://localhost:8080/docs/`
- OpenAPI spec: [`Public/openapi.yaml`](Public/openapi.yaml)

## Environment variables

| Variable | Default | Notes |
|---|---|---|
| `JWT_SECRET` | insecure dev secret (non-prod only) | required in production, refuses to boot without it |
| `LLM_API_KEY` | — | Claude API key, required for extraction/checkup |
| `CHECKUP_MODEL` | `claude-haiku-4-5` | model used for checkup generation |
| `REDIS_URL` | unset (queue disabled) | e.g. `redis://localhost:6379` |
| `RESEND_API_KEY` | unset (emails only logged) | required to actually send verification codes |
| `MAIL_FROM` | `Healthside <onboarding@resend.dev>` | sandbox address unless a domain is verified on Resend |
| `RATE_LIMIT_VERIFY_EMAIL` | `10` | requests per client IP per 60s window |
| `RATE_LIMIT_RESEND_VERIFICATION` | `5` | requests per client IP per 60s window |
| `DATABASE_HOST` / `PORT` / `USERNAME` / `PASSWORD` / `NAME` | `localhost` / `5432` / `vapor_username` / `vapor_password` / `vapor_database` | matches the `db` service in `docker-compose.yml` |
| `DATABASE_NAME_TEST` | `vapor_test` | used only when `app.environment == .testing` |
| `STORAGE_PATH` | `<working dir>/storage/lab-results/` | where uploaded files are written on disk |
| `RATE_LIMIT_LOGIN` / `RATE_LIMIT_REGISTER` | `10` | requests per client IP per 60s window |

The extraction model is currently hardcoded to `claude-haiku-4-5` in `ExtractionJob.swift`, not configurable via env.

`.env.example` only lists the ones you're expected to set for local dev (`JWT_SECRET`, `LLM_API_KEY`, `REDIS_URL`); the rest have working defaults. Secrets live in the environment only — never in code, never committed.

## Layout

```
Sources/Healthside/
  Controllers/     HTTP handlers (Auth, LabResult, Document, Checkup, User)
  Models/          Fluent models
  Migrations/      versioned schema
  Services/        extraction, de-identification, checkup assembly
  LLM/             Claude API integration — provider, prompts, extraction schema
  Jobs/            queue jobs (ExtractionJob)
  Middleware/      rate limiting, security headers
  Storage/         file storage, upload validation
  Authentication/  JWT access-token authenticator
```

## Further docs

Architecture, data flow, security/privacy, compliance notes, and prompts live in the `HealthSideDocs` vault (not part of this repo).
