#!/usr/bin/env bash
# ============================================================================
#  IRIS v3 (DFIR-IRIS 3.0.0-beta.1) + Kaspersky MDR sync — установщик
#  Перенос с Kali-стенда на целевой сервер, где уже работает ДРУГОЙ IRIS.
#
#  Ключевые решения:
#    * свой compose-проект (по умолчанию iris3) -> свои сети и тома;
#    * свои имена контейнеров (iris3_*) -> не конфликтуют с существующим iris_*;
#    * свой внешний порт (по умолчанию 8446) -> существующий IRIS не трогаем;
#    * БД разворачивается из дампа и живёт в томе iris3_db_data.
#
#  Использование (от root):
#      sudo ./install.sh
#  Переопределяемое окружение:
#      IRIS_DIR=/opt/iris3 PROJECT=iris3 CTR_PREFIX=iris3_ \
#      HOST_HTTPS_PORT=8446 PUBLIC_HOST=10.0.0.5 RUN_USER=root \
#      INSTALL_SYNC=1 SKIP_DB_RESTORE=0 ./install.sh
# ============================================================================
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IRIS_DIR="${IRIS_DIR:-/opt/iris3}"
SYNC_DIR="${SYNC_DIR:-/opt/mdr-iris-sync}"
PROJECT="${PROJECT:-iris3}"
CTR_PREFIX="${CTR_PREFIX:-iris3_}"
HOST_HTTPS_PORT="${HOST_HTTPS_PORT:-8446}"
PUBLIC_HOST="${PUBLIC_HOST:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
RUN_USER="${RUN_USER:-$(id -un)}"
INSTALL_SYNC="${INSTALL_SYNC:-1}"
SKIP_DB_RESTORE="${SKIP_DB_RESTORE:-0}"
WAIT_APP_SECS="${WAIT_APP_SECS:-420}"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "запускать от root: sudo ./install.sh"

command -v docker >/dev/null || die "docker не установлен"
docker compose version >/dev/null 2>&1 || die "docker compose (v2) не установлен"
command -v python3 >/dev/null || die "python3 не установлен"

export HOST_HTTPS_PORT PROJECT CTR_PREFIX PUBLIC_HOST

log "проект=$PROJECT префикс=$CTR_PREFIX каталог=$IRIS_DIR порт=$HOST_HTTPS_PORT хост=$PUBLIC_HOST"

# ---------------------------------------------------------------- порт ----
if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${HOST_HTTPS_PORT}\$"; then
  die "порт $HOST_HTTPS_PORT уже занят. Задай другой: HOST_HTTPS_PORT=8447 ./install.sh"
fi

# --------------------------------------------- существующий IRIS рядом ----
if docker ps -a --format '{{.Names}}' | grep -q "^${CTR_PREFIX}"; then
  warn "контейнеры с префиксом ${CTR_PREFIX} уже есть — это повторная установка?"
  docker ps -a --format '  {{.Names}}\t{{.Status}}' | grep "^  ${CTR_PREFIX}" || true
fi
if docker ps --format '{{.Names}}' | grep -qE '^iris_(app|db|nginx)$'; then
  log "обнаружен существующий IRIS (iris_*) — он не будет затронут"
fi
if docker network ls --format '{{.Name}}' | grep -qx "${PROJECT}_iris_backend"; then
  warn "сеть ${PROJECT}_iris_backend уже существует — будет переиспользована"
fi

# ------------------------------------------------------------- файлы -----
log "копирую файлы в $IRIS_DIR"
mkdir -p "$IRIS_DIR"
cp -a "$SRC_DIR/iris/." "$IRIS_DIR/"
chmod 600 "$IRIS_DIR/.env" "$IRIS_DIR/iris-secrets.txt" 2>/dev/null || true
mkdir -p "$IRIS_DIR/certificates/ldap"

# ------------------------------------------- патчи compose, .env, cert ----
log "патчу docker-compose.yml (имена контейнеров, сетей и порт)"
python3 - "$IRIS_DIR/docker-compose.yml" "$CTR_PREFIX" "$HOST_HTTPS_PORT" "$PROJECT" <<'PY'
import re, sys
path, prefix, port, project = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
s = open(path, encoding='utf-8').read()
s = re.sub(r'^(\s*)container_name:\s*iris_', r'\1container_name: ' + prefix, s, flags=re.M)
s = re.sub(r'(name:\s*)iris_(backend|frontend)', r'\g<1>' + project + r'_iris_\g<2>', s)
old = '"${INTERFACE_HTTPS_PORT:-443}:${INTERFACE_HTTPS_PORT:-443}"'
new = '"${HOST_HTTPS_PORT:-%s}:${INTERFACE_HTTPS_PORT:-443}"' % port
if old in s:
    s = s.replace(old, new)
elif '${HOST_HTTPS_PORT' not in s:
    raise SystemExit('не найдена строка ports для nginx — проверь compose вручную')
open(path, 'w', encoding='utf-8').write(s)
PY

log "правлю .env (hostname/server_name/URL фронтенда)"
python3 - "$IRIS_DIR/.env" "$PUBLIC_HOST" "$HOST_HTTPS_PORT" <<'PY'
import sys
path, host, port = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path, encoding='utf-8').read().splitlines()
def setkv(lines, k, v):
    for i, l in enumerate(lines):
        if l.startswith(k + '='):
            lines[i] = f'{k}={v}'
            return lines
    return lines + [f'{k}={v}']
url = f'https://{host}:{port}'
lines = setkv(lines, 'IRIS_HOSTNAME', host)
lines = setkv(lines, 'SERVER_NAME', host)
lines = setkv(lines, 'HOST_HTTPS_PORT', port)
lines = setkv(lines, 'PUBLIC_EXTERNAL_API_URL', url)
lines = setkv(lines, 'IRIS_ALLOW_ORIGIN', url)
open(path, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
PY

# ------------------------------------------------------------- образы -----
IMG_TAR="$SRC_DIR/iris/images/iris-images.tar"
if [[ -f "$IMG_TAR" ]]; then
  log "загружаю образы из $IMG_TAR (офлайн)"
  docker load -i "$IMG_TAR"
else
  warn "архив образов не найден — недостающие образы compose скачает при запуске (нужен интернет)"
fi

# --------------------------------------------------------- БД и импорт ----
log "поднимаю db + rabbitmq"
( cd "$IRIS_DIR" && docker compose -p "$PROJECT" up -d db rabbitmq )

log "жду готовности postgres"
for i in $(seq 1 60); do
  if docker exec "${CTR_PREFIX}db" pg_isready -U postgres -d iris_db >/dev/null 2>&1; then break; fi
  sleep 2
  [[ $i -eq 60 ]] && die "postgres не поднялся за 120 c"
done

if [[ "$SKIP_DB_RESTORE" != "1" && -f "$SRC_DIR/iris/db/iris_db.dump" ]]; then
  log "восстанавливаю БД из дампа"
  if ! docker exec -i "${CTR_PREFIX}db" pg_restore -U postgres -d iris_db --no-owner --no-privileges < "$SRC_DIR/iris/db/iris_db.dump"; then
    warn "pg_restore вернул ошибки — проверь вывод выше"
  fi
else
  warn "дамп не найден или SKIP_DB_RESTORE=1 — будет пустая база"
fi

# ---------------------------------------------------------- весь стек -----
log "запускаю стек ($PROJECT)"
( cd "$IRIS_DIR" && docker compose -p "$PROJECT" up -d )

log "жду healthy app (до ${WAIT_APP_SECS}c)"
deadline=$(( $(date +%s) + WAIT_APP_SECS ))
until docker exec "${CTR_PREFIX}app" curl -sf -o /dev/null http://localhost:8000 2>/dev/null; do
  [[ $(date +%s) -gt $deadline ]] && { docker compose -p "$PROJECT" ps; die "app не поднялся"; }
  sleep 5
done

log "проверяю HTTPS на порту $HOST_HTTPS_PORT"
code=$(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1:${HOST_HTTPS_PORT}/" || true)
[[ "$code" == "200" ]] && log "UI отвечает 200" || warn "UI вернул $code — смотри docker logs ${CTR_PREFIX}nginx"

# --------------------------------------------------------------- LDAP -----
if [[ -f "$SRC_DIR/ldap.env" ]]; then
  log "применяю LDAP-настройки из ldap.env"
  python3 - "$IRIS_DIR/.env" "$SRC_DIR/ldap.env" <<'PY'
import sys
env_path, ldap_path = sys.argv[1], sys.argv[2]
lines = open(env_path, encoding='utf-8').read().splitlines()
def setkv(lines, k, v):
    for i, l in enumerate(lines):
        if l.startswith(k + '='):
            lines[i] = f'{k}={v}'
            return lines
    return lines + [f'{k}={v}']
for raw in open(ldap_path, encoding='utf-8'):
    raw = raw.strip()
    if not raw or raw.startswith('#') or '=' not in raw:
        continue
    k, v = raw.split('=', 1)
    lines = setkv(lines, k.strip(), v.strip())
lines = setkv(lines, 'IRIS_AUTHENTICATION_TYPE', 'ldap')
open(env_path, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
PY
  chmod 600 "$IRIS_DIR/.env"
  ( cd "$IRIS_DIR" && docker compose -p "$PROJECT" up -d --force-recreate app worker nginx )
  log "LDAP включён (local-фолбэк админа остаётся, если IRIS_AUTHENTICATION_LOCAL_FALLBACK=True)"
else
  warn "ldap.env не найден — оставляю локальную аутентификацию"
fi

# ---------------------------------------------------------------- sync ----
if [[ "$INSTALL_SYNC" == "1" ]]; then
  log "ставлю MDR→IRIS sync в $SYNC_DIR"
  mkdir -p "$SYNC_DIR"
  cp -a "$SRC_DIR/sync/." "$SYNC_DIR/"
  chmod 600 "$SYNC_DIR/config.json" "$SYNC_DIR/state/mdr_tokens.json" 2>/dev/null || true

  python3 -m venv "$SYNC_DIR/.venv"
  "$SYNC_DIR/.venv/bin/pip" install --quiet --upgrade pip
  "$SYNC_DIR/.venv/bin/pip" install --quiet -r "$SYNC_DIR/requirements.txt"

  python3 - "$SYNC_DIR/config.json" "$HOST_HTTPS_PORT" "$SYNC_DIR" <<'PY'
import json, sys
path, port, sync_dir = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(path, encoding='utf-8'))
d.setdefault('iris', {})['api_url'] = f'https://127.0.0.1:{port}'
d['iris']['verify'] = False
d.setdefault('state_db', 'state/sync.db')
logf = d.get('log') or {}
logf.setdefault('file', 'logs/sync.log')
d['log'] = logf
json.dump(d, open(path, 'w', encoding='utf-8'), indent=2, ensure_ascii=False)
PY

  mkdir -p "$SYNC_DIR/logs" "$SYNC_DIR/state"
  chown -R "$RUN_USER":"$RUN_USER" "$SYNC_DIR" || true

  cat > /etc/systemd/system/mdr-iris-sync.service <<EOF
[Unit]
Description=Kaspersky MDR to DFIR-IRIS synchronization
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_USER}
WorkingDirectory=${SYNC_DIR}
Environment=PYTHONUNBUFFERED=1
ExecStart=${SYNC_DIR}/.venv/bin/python -m mdr_iris_sync --config config.json
Restart=always
RestartSec=10
TimeoutStopSec=30
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now mdr-iris-sync
  sleep 5
  systemctl is-active --quiet mdr-iris-sync && log "sync-сервис запущен" || warn "sync-сервис не активен: journalctl -u mdr-iris-sync -n 50"
fi

# ------------------------------------------------------------- итог ------
cat <<EOF

============================================================================
Готово.

  UI:            https://${PUBLIC_HOST}:${HOST_HTTPS_PORT}/   (самоподписанный серт)
  Проект:        ${PROJECT}   (контейнеры ${CTR_PREFIX}*)
  Каталог:       ${IRIS_DIR}
  Секреты:       ${IRIS_DIR}/iris-secrets.txt  (chmod 600)
  БД:            том ${PROJECT}_db_data, дамп в ${SRC_DIR}/iris/db/
  LDAP:          $([[ -f "$SRC_DIR/ldap.env" ]] && echo "включён из ldap.env" || echo "не настроен (local)")

Проверки:
  docker compose -p ${PROJECT} ps
  curl -sk https://127.0.0.1:${HOST_HTTPS_PORT}/api/v2/cases -H "Authorization: Bearer <API_KEY>"
  systemctl status mdr-iris-sync
  journalctl -u mdr-iris-sync -n 50
============================================================================
EOF
