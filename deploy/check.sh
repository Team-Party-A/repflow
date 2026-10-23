#!/bin/sh
set -eu
: "${API_IMAGE:?Build and set the runtime image}"
: "${TEST_IMAGE:?Build and set the test image}"
script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
project_name="repflow-check-$$"
scratch_dir=$(mktemp -d)
export POSTGRES_DB=repflow_test POSTGRES_USER=repflow_test
export POSTGRES_PASSWORD=repflow_test_only HTTP_BIND=127.0.0.1 HTTP_PORT=0
compose() {
    docker compose --env-file /dev/null -p "$project_name" -f "$script_dir/compose.yaml" "$@"
}
cleanup() {
    check_status=$?
    trap - EXIT HUP INT TERM
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
        actual_code=$(curl -sS --max-time 6 -o "$scratch_dir/health.json" -w '%{http_code}' "$health_url") || actual_code=000
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
compose config --quiet
compose up -d --wait --wait-timeout 120
health_url="http://$(compose port nginx 80)/health"
expect_health 200 ok
docker run --rm --network "${project_name}_backend" \
    -e DB_HOST=db -e DB_NAME="$POSTGRES_DB" -e DB_USER="$POSTGRES_USER" \
    -e DB_PASSWORD="$POSTGRES_PASSWORD" "$TEST_IMAGE" sh -ec \
    'uv run --locked ruff format --check .; uv run --locked ruff check .; uv run --locked pytest --cov=app --cov-report=term-missing'
compose stop db
expect_health 503 unavailable
compose up -d --wait --wait-timeout 120 db
expect_health 200 ok

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
