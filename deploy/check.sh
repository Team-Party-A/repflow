#!/bin/sh
set -eu
: "${API_IMAGE:?Build and set the runtime image}"
: "${TEST_IMAGE:?Build and set the test image}"
script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
project_name="repflow-check-$$"
scratch_dir=$(mktemp -d)
export POSTGRES_DB=repflow_test POSTGRES_USER=repflow_test
export POSTGRES_PASSWORD=repflow_test_only HTTP_BIND=127.0.0.1 HTTP_PORT=0
database_paused=0
compose() {
    docker compose --env-file /dev/null -p "$project_name" -f "$scratch_dir/compose.yaml" "$@"
}
cleanup() {
    check_status=$?
    trap - EXIT HUP INT TERM
    if [ "$database_paused" -eq 1 ]; then
        if ! compose unpause db >/dev/null 2>&1; then
            printf 'failed to unpause temporary database during cleanup\n' >&2
            check_status=1
        fi
    fi
    if [ "$check_status" -ne 0 ]; then compose logs --no-color --tail 50 >&2 || true; fi
    docker rm -f "$project_name-ip-holder" >/dev/null 2>&1 || true
    compose down --volumes --remove-orphans >/dev/null 2>&1 || true
    rm -rf "$scratch_dir"
    exit "$check_status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
expect_health() {
    expected_code=$1 expected_state=$2
    attempts=0
    while [ "$attempts" -lt 30 ]; do
        actual_code=$(curl -sS --max-time 6 -D "$scratch_dir/health.headers" -o "$scratch_dir/health.json" -w '%{http_code}' "$health_url") || actual_code=000
        if [ "$actual_code" = "$expected_code" ]; then
            python3 - "$scratch_dir/health.json" "$expected_state" <<'PY'
import json
import sys
with open(sys.argv[1]) as response:
    assert json.load(response) == {"status": sys.argv[2]}
PY
            return
        fi
        attempts=$((attempts + 1))
        sleep 1
    done
    printf 'health check failed: expected=%s actual=%s\n' "$expected_code" "$actual_code" >&2
    return 1
}
expect_config_header() {
    python3 - "$scratch_dir/health.headers" "$1" <<'PY'
import sys
with open(sys.argv[1]) as response:
    values = [line.split(":", 1)[1].strip() for line in response
              if line.lower().startswith("x-repflow-config:")]
assert values == ([sys.argv[2]] if sys.argv[2] else []), values
PY
}
# 只改临时副本；原子替换文件可覆盖单文件挂载仍指向旧 inode 的情况。
cp "$script_dir/compose.yaml" "$scratch_dir/compose.yaml"
cp "$script_dir/nginx.conf" "$scratch_dir/nginx.conf"
cp "$script_dir/nginx.conf" "$scratch_dir/nginx.original"
compose config --quiet
compose run --rm --no-deps nginx nginx -t
compose up -d --wait --wait-timeout 120 db api
compose up -d --no-deps --force-recreate --wait --wait-timeout 120 nginx
health_url="http://$(compose port nginx 80)/health"
expect_health 200 ok
expect_config_header ''

for config_state in invalid updated original; do
    previous_nginx=$(compose ps -q nginx)
    python3 - "$scratch_dir" "$config_state" <<'PY'
from pathlib import Path
import sys
directory = Path(sys.argv[1])
source = (directory / "nginx.original").read_text()
if sys.argv[2] == "invalid":
    source += "\ninvalid_repflow_directive;\n"
elif sys.argv[2] == "updated":
    location = "location = /health {"
    assert source.count(location) == 1
    source = source.replace(location, location + "\n            add_header X-Repflow-Config updated always;", 1)
candidate = directory / "nginx.next"
candidate.write_text(source)
candidate.replace(directory / "nginx.conf")
PY
    if [ "$config_state" = invalid ]; then
        if compose run --rm --no-deps nginx nginx -t >"$scratch_dir/nginx-invalid.log" 2>&1; then
            printf 'invalid nginx configuration was accepted\n' >&2
            exit 1
        fi
        grep -Fq 'unknown directive "invalid_repflow_directive"' "$scratch_dir/nginx-invalid.log"
        test "$previous_nginx" = "$(compose ps -q nginx)"
        expect_health 200 ok
        expect_config_header ''
        continue
    fi
    compose run --rm --no-deps nginx nginx -t
    compose up -d --no-deps --force-recreate --wait --wait-timeout 120 nginx
    test "$previous_nginx" != "$(compose ps -q nginx)"
    health_url="http://$(compose port nginx 80)/health"
    expect_health 200 ok
    if [ "$config_state" = updated ]; then
        expect_config_header updated
    else
        expect_config_header ''
    fi
done
printf 'nginx checks passed: invalid candidate rejected, updated header observed, rollback header removed.\n'

docker run --rm --network "${project_name}_backend" \
    -e DB_HOST=db -e DB_NAME="$POSTGRES_DB" -e DB_USER="$POSTGRES_USER" \
    -e DB_PASSWORD="$POSTGRES_PASSWORD" "$TEST_IMAGE" sh -ec \
    'uv run --locked ruff format --check .; uv run --locked ruff check .; uv run --locked pytest --cov=app --cov-report=term-missing'
compose stop db
expect_health 503 unavailable
compose up -d --wait --wait-timeout 120 db
expect_health 200 ok

# 真实暂停已有连接，覆盖驱动等待取消确认导致代理先返回 504 的情况。
compose pause db
database_paused=1
timeout_code=$(curl -sS --max-time 4.5 -o "$scratch_dir/timeout.json" -w '%{http_code}' "$health_url")
test "$timeout_code" = 503
python3 - "$scratch_dir/timeout.json" <<'PY'
import json
import sys
with open(sys.argv[1]) as response:
    assert json.load(response) == {"status": "unavailable"}
PY
compose unpause db
database_paused=0
expect_health 200 ok
printf 'Database timeout checks passed: paused database returned 503 within proxy deadline, recovery returned 200.\n'

# 加入临时容器改变地址分配，再断言 API 确实换址，避免 DNS 测试侥幸通过。
api_id=$(compose ps -q api)
old_address=$(docker inspect -f "{{with index .NetworkSettings.Networks \"${project_name}_frontend\"}}{{.IPAddress}}{{end}}" "$api_id")
nginx_image=$(docker inspect -f '{{.Config.Image}}' "$(compose ps -q nginx)")
compose rm --stop --force api
docker run -d --name "$project_name-ip-holder" --network "${project_name}_frontend" \
    --entrypoint sleep "$nginx_image" 120 >/dev/null
compose up -d --no-deps --wait --wait-timeout 120 api
new_address=$(docker inspect -f "{{with index .NetworkSettings.Networks \"${project_name}_frontend\"}}{{.IPAddress}}{{end}}" "$(compose ps -q api)")
test "$old_address" != "$new_address"
expect_health 200 ok
docker rm -f "$project_name-ip-holder" >/dev/null

cluster_before=$(compose exec -T db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT system_identifier FROM pg_control_system()"')
compose down
compose up -d --wait --wait-timeout 120
health_url="http://$(compose port nginx 80)/health"
expect_health 200 ok
cluster_after=$(compose exec -T db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT system_identifier FROM pg_control_system()"')
test "$cluster_before" = "$cluster_after"
printf 'Compose checks passed: database recovery, API DNS refresh, persistent cluster.\n'
