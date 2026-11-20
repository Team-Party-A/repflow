ARG SWAGGER_UI_SHA256=1b8e891893404ea4c3558b6a87e2a3e494e7eedba41168c2ece5800a391a6ea6
FROM ghcr.io/astral-sh/uv:0.13.5@sha256:32a7bb39b496babbd997b0a39a4d66c126bdaf5661b302bf6f06abda8deca6ff AS uv
FROM scratch AS swagger_package
ARG SWAGGER_UI_SHA256
ADD --checksum=sha256:${SWAGGER_UI_SHA256} https://registry.npmjs.org/swagger-ui-dist/-/swagger-ui-dist-5.35.0.tgz /swagger.tgz

FROM python:3.14.9-slim-trixie@sha256:b347e2dcbc7f0b6f9fb7182e9da6a187fb10ae715e0692518c1aed0eec94a700 AS swagger_assets
ARG SWAGGER_UI_SHA256
COPY --from=swagger_package /swagger.tgz /tmp/swagger.tgz
RUN printf '%s  /tmp/swagger.tgz\n' "$SWAGGER_UI_SHA256" | sha256sum -c - && \
    mkdir -p /docs-assets && \
    tar -xzf /tmp/swagger.tgz -C /docs-assets --strip-components=1 \
        package/swagger-ui-bundle.js package/swagger-ui.css package/LICENSE \
        package/NOTICE package/swagger-ui-bundle.js.LICENSE.txt && \
    cat /docs-assets/LICENSE /docs-assets/NOTICE /docs-assets/swagger-ui-bundle.js.LICENSE.txt > /docs-assets/licenses.txt

FROM python:3.14.9-slim-trixie@sha256:b347e2dcbc7f0b6f9fb7182e9da6a187fb10ae715e0692518c1aed0eec94a700 AS base
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 UV_PYTHON_DOWNLOADS=never UV_LINK_MODE=copy
COPY --from=uv /uv /usr/local/bin/uv
COPY pyproject.toml uv.lock .python-version ./
RUN uv sync --locked --no-dev
COPY app ./app
COPY --from=api_contract /openapi.yaml /nutrition.yaml ./app/api_docs/
COPY --from=swagger_assets /docs-assets/swagger-ui-bundle.js /docs-assets/swagger-ui.css /docs-assets/licenses.txt ./app/api_docs/
COPY alembic.ini ./
COPY migrations ./migrations

FROM base AS test
RUN uv sync --locked
COPY tests ./tests
CMD ["uv", "run", "--locked", "pytest", "--cov=app", "--cov-report=term-missing"]

FROM python:3.14.9-slim-trixie@sha256:b347e2dcbc7f0b6f9fb7182e9da6a187fb10ae715e0692518c1aed0eec94a700 AS runtime
WORKDIR /app
ENV PATH="/app/.venv/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
COPY --from=base /app/.venv /app/.venv
COPY --from=base /app/app /app/app
COPY --from=base /app/alembic.ini /app/alembic.ini
COPY --from=base /app/migrations /app/migrations
USER 10001:10001
LABEL org.opencontainers.image.source="https://github.com/Team-Party-A/repflow"
CMD ["uvicorn", "app.main:create_app", "--factory", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--log-level", "info", "--no-access-log"]
