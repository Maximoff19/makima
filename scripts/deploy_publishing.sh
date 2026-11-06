#!/usr/bin/env bash
# Deploy the publishing stack (nginx on IP:port + agent write access + super-chat fixes).
#
# Idempotent and fail-fast. nginx -t runs against the uploaded config BEFORE the container is
# started, so a bad config can never take the site down.
#
#   ./scripts/deploy_publishing.sh
#
# Env: VPS (required SSH host), ROOT (/opt/makima), PORT (8085), WEB_HOST (VPS public IP).
set -euo pipefail

VPS="${VPS:?Set VPS to the SSH host}"
ROOT="${ROOT:-/opt/makima}"
PORT="${PORT:-8085}"
WEB_HOST="${WEB_HOST:?Set WEB_HOST to the public host or IP}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

say "Preflight: is the VPS reachable?"
if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$VPS" true; then
  echo "No se pudo conectar por SSH a $VPS." >&2
  echo "Si 443 responde pero 22 no, el puerto esta filtrado en la red local (fail2ban o filtro del operador)." >&2
  exit 1
fi

say "Backup del estado actual en el VPS"
STAMP="$(ssh "$VPS" "set -e; stamp=\$(date +%Y%m%d-%H%M%S); mkdir -p $ROOT/backups/\$stamp/gateway; \
  cp -a $ROOT/docker-compose.yml $ROOT/docker-compose.opencode.yml $ROOT/.env $ROOT/backups/\$stamp/ 2>/dev/null || true; \
  cp -a $ROOT/config/nginx.conf $ROOT/backups/\$stamp/ 2>/dev/null || true; \
  cp -a $ROOT/gateway/app.py $ROOT/gateway/opencode_bridge.py $ROOT/backups/\$stamp/gateway/ 2>/dev/null || true; \
  cp -a $ROOT/gateway/skills $ROOT/backups/\$stamp/gateway/ 2>/dev/null || true; \
  echo \$stamp" | tail -1)"
echo "backup: $ROOT/backups/$STAMP"

say "Subiendo archivos"
rsync -az "$HERE/docker-compose.yml" "$HERE/docker-compose.opencode.yml" "$VPS:$ROOT/"
rsync -az "$HERE/config/nginx.conf" "$VPS:$ROOT/config/nginx.conf"
rsync -az "$HERE/config/opencode.json" "$VPS:$ROOT/data/opencode-workspace/opencode.json"
rsync -az "$HERE/gateway/app.py" "$HERE/gateway/opencode_bridge.py" "$HERE/gateway/agenda.py" "$VPS:$ROOT/gateway/"
rsync -az --delete "$HERE/gateway/skills/" "$VPS:$ROOT/gateway/skills/"
rsync -az "$HERE/gateway/Dockerfile" "$HERE/gateway/requirements.txt" "$VPS:$ROOT/gateway/"

say "Preparando el directorio de publicacion"
ssh "$VPS" "set -e
  # uid 10001 es el del contenedor opencode: sin esto el agente no puede escribir y nada se publica.
  mkdir -p $ROOT/data/web
  chown -R 10001:10001 $ROOT/data/web
  chmod 755 $ROOT/data/web
  # El secret de Vercel es opcional: sin el, el agente publica solo en nginx.
  if [ ! -f $ROOT/config/vercel_token ]; then
    printf '' > $ROOT/config/vercel_token
    chmod 600 $ROOT/config/vercel_token
    echo 'NOTA: config/vercel_token vacio. El deploy a Vercel quedara deshabilitado.'
  fi
  chown 10001:10001 $ROOT/config/vercel_token 2>/dev/null || true"

say "nginx -t contra la config subida (antes de levantar nada)"
ssh "$VPS" "set -e
  docker run --rm \
    -v $ROOT/config/nginx.conf:/etc/nginx/conf.d/default.conf:ro \
    -v $ROOT/data/web:/usr/share/nginx/html:ro \
    nginx:1.27-alpine nginx -t"

say "Levantando el stack"
ssh "$VPS" "set -e; cd $ROOT && docker compose -f docker-compose.yml -f docker-compose.opencode.yml up -d --build"

say "Estado"
ssh "$VPS" "docker ps --filter name=makima --format '{{.Names}}\t{{.Status}}' | sort"

say "Smoke tests"
sleep 8
ssh "$VPS" "set -e
  echo -n 'gateway health: '; docker exec makima-gateway-1 python -c \"import httpx;print(httpx.get('http://127.0.0.1:8000/health').status_code)\"
  echo -n 'nginx en $PORT:  '; curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:$PORT/ || true; echo ' (403 = directorio vacio con autoindex off: normal hasta que se publique algo)'"

cat <<EOF

Listo. Backup en $ROOT/backups/$STAMP

Probalo desde el chat Super:
  "Makima, creá un proyecto web llamado proyecto-web en /proyecto-web y publicalo"
Y después abrilo en:
  http://$WEB_HOST:$PORT/proyecto-web/

Para Vercel: poné el token en $ROOT/config/vercel_token (chmod 600) y reinicia el opencode.

Volver atras:
  ssh $VPS 'cd $ROOT && cp -a backups/$STAMP/docker-compose.yml backups/$STAMP/docker-compose.opencode.yml . && cp -a backups/$STAMP/gateway/. gateway/ && cp -a backups/$STAMP/nginx.conf config/ && docker compose -f docker-compose.yml -f docker-compose.opencode.yml up -d --build'
EOF
