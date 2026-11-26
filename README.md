# IRIS v3 stand — патчи и деплой

Отдельный репозиторий для кастомных патчей и конфигурации стенда **DFIR-IRIS 3.0.0-beta.1**
(ранее жили внутри `kaspersky-mdr-iris-sync/stand/iris-patch`).

## Что внутри

- `patches/backend/tasks.py` — порядок задач в кейсах (закрывающая задача последней)
- `patches/backend/Dockerfile` — сборка backend с патчами
- `patches/compose/docker-compose.override.yml` — mounted-патчи, nginx, gzip/http2/immutable
- `patches/patches/*` — nginx.conf, configuration.py (CORS/origin), агрегации дашборда, ctx.js, models_cases.py, schema_marshables.py
- `patches/patches/50-iris-patch-after-start.sh` — патч nginx после старта (entrypoint в фоне)
- `scripts/install.sh` — установщик IRIS3 рядом с существующим IRIS (свой compose-проект `iris3`, порт 8446)
- `scripts/reapply-patches.sh` — переприменение mounted-патчей после обновления образа
- `scripts/verify.sh` — smoke-проверка стенда (gzip, h2, origin, логин, API)
- `UPGRADE_CHECKLIST.md` — чек-лист обновления IRIS

## Переменные окружения

См. `scripts/ldap.env.example`. Рабочий `.env` содержит секреты и **в репозиторий не попадает**.

## Деплой (кратко)

1. Docker + docker compose v2 на хосте.
2. Клонировать `dfir-iris/iris-web` версии `v3.0.0-beta.1` (образы с ghcr.io/dfir-iris).
3. Скопировать патчи, применить `docker-compose.override.yml`.
4. `.env`: `IRIS_HOSTNAME`, `SERVER_NAME`, `INTERFACE_HTTPS_PORT=8446`, пароли БД, `IRIS_SECRET_KEY`, `IRIS_SECURITY_PASSWORD_SALT`.
5. `docker compose up -d`, дождаться healthy, проверить `scripts/verify.sh`.

## Текущий стенд (26.11.2026)

- Хост: IRIS_HOST (Ubuntu 24.04), стек `/opt/iris-web`, порт **8446/tcp** (самоподписанный серт).
- Контейнеры: iris_nginx, iris_app, iris_worker, iris_db, iris_rabbitmq, iris_frontend.
- Домен `neko.vbrr.online` пока указывает на мёртвый IRIS_HOST_OLD — после смены A-записи на IRIS_HOST поставить Let's Encrypt сертификат.
- БД чистая: кейсы/шаблоны задач/настройки со старого хоста не сохранились (дампа не было).
