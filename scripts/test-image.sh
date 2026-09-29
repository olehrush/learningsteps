#!/usr/bin/env bash
set -euo pipefail
image_ref="${1:?Usage: bash scripts/test-image.sh IMAGE_REF}"
task_suffix="$(python3 -c 'import secrets; print(secrets.token_hex(5))')"
task_net="ls-test-${task_suffix}"
task_db="ls-db-${task_suffix}"
task_api="ls-api-${task_suffix}"
task_env="$(mktemp)"
chmod 600 "$task_env"

cleanup() {
  docker rm -f "$task_api" "$task_db" >/dev/null 2>&1 || true
  docker network rm "$task_net" >/dev/null 2>&1 || true
  rm -f "$task_env"
}
trap cleanup EXIT

python3 - "$task_env" <<'PY'
import secrets, sys
password = secrets.token_urlsafe(24)
with open(sys.argv[1], 'w') as file:
    file.write('POSTGRES_USER=postgres\nPOSTGRES_DB=learning_journal\n')
    file.write(f'POSTGRES_PASSWORD={password}\n')
    file.write(f'DATABASE_URL=postgresql://postgres:{password}@postgres:5432/learning_journal\n')
PY

docker network create "$task_net" >/dev/null
docker run -d --name "$task_db" --network "$task_net" --network-alias postgres \
  --env-file "$task_env" \
  -v "$PWD/database_setup.sql:/docker-entrypoint-initdb.d/01-schema.sql:ro" \
  postgres:16-bookworm >/dev/null

db_ready=false
for attempt in $(seq 1 60); do
  if docker exec "$task_db" psql -U postgres -d learning_journal -tAc \
    "SELECT to_regclass('public.entries')" 2>/dev/null | grep -q entries; then
    db_ready=true
    break
  fi
  sleep 1
done
if [ "$db_ready" != true ]; then
  echo 'PostgreSQL test schema was not ready within 60 seconds.' >&2
  exit 1
fi

docker run -d --name "$task_api" --network "$task_net" \
  --env-file "$task_env" -p 127.0.0.1::8000 "$image_ref" >/dev/null
binding="$(docker port "$task_api" 8000/tcp)"
base_url="http://127.0.0.1:${binding##*:}"

python3 - "$base_url" <<'PY'
import sys, time, urllib.request
for attempt in range(60):
    try:
        with urllib.request.urlopen(sys.argv[1] + '/health/ready', timeout=2) as response:
            if response.status == 200:
                break
    except Exception:
        time.sleep(1)
else:
    raise SystemExit('API readiness did not pass; inspect Docker startup/configuration.')
PY
python3 scripts/smoke_api.py --base-url "$base_url"
