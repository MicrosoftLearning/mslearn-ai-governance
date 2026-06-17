# Base images are parameterized so the build can pull them from a registry that
# is not rate-limited (e.g. a copy imported into your ACR with `az acr import`).
# Defaults use the public images directly.
ARG BASE_IMAGE=python:3.13-slim
ARG UV_IMAGE=ghcr.io/astral-sh/uv:latest

FROM ${UV_IMAGE} AS uv
FROM ${BASE_IMAGE}

COPY --from=uv /uv /uvx /bin/

ENV UV_SYSTEM_PYTHON=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    PORT=8080

WORKDIR /app
COPY mcp-hr/server/requirements.txt .
RUN uv pip install --system --no-cache --prerelease=if-necessary-or-explicit -r requirements.txt

COPY mcp-hr/server/ ./mcp-hr/server/
WORKDIR /app/mcp-hr/server

EXPOSE 8080

CMD ["python", "server.py"]
