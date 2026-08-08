# Docker Containerization with `uv` & Conditional Dev Dependencies

## Overview

This guide details the modern architecture for containerizing Python applications (specifically Django REST Framework APIs) using **Astral `uv`** as the fast package manager, `pyproject.toml` for dependency management, and conditional build arguments in Docker & Docker Compose.

---

## Key Architecture & Setup Concepts

### 1. Astral `uv` in Docker

- **Fast Installation**: `uv` is written in Rust and provides 10-100x faster package resolution and installation compared to standard `pip`.
- **Binary Copying**: Instead of installing `uv` via `pip` inside the container, copy the static binary directly from the official image:
  ```dockerfile
  COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/
  ```
- **Virtual Environment Isolation**: Create a dedicated `/py` virtual environment inside the container using `uv venv /py` and set `ENV PATH="/py/bin:$PATH"`.

### 2. Dependency Specification (`pyproject.toml`)

Standard PEP 621 configuration separating production and development dependencies:

```toml
[project]
name = "python-recipe-app-api"
version = "0.1.0"
dependencies = [
    "Django>=3.2.4,<3.3",
    "djangorestframework>=3.12.4,<3.13",
    "uvicorn>=0.22.0,<1.0",
]

[project.optional-dependencies]
dev = [
    "flake8>=3.9.2,<3.10",
]

[dependency-groups]
dev = [
    "flake8>=3.9.2,<3.10",
]
```

### 3. Conditional Dev Dependency Installation (`Dockerfile`)

Using build argument `ARG DEV=false` to dynamically determine whether to install development dependencies (`flake8`) or only core production dependencies:

```dockerfile
FROM python:3.9-alpine3.13
LABEL maintainer="rhishikesh-chikhalkar"

ENV PYTHONUNBUFFERED=1
WORKDIR /app

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

COPY pyproject.toml /tmp/
COPY . /app

EXPOSE 8000

ARG DEV=false
RUN uv venv /py && \
    if [ "$DEV" = "true" ]; then \
        uv pip install --python /py "/tmp[dev]"; \
    else \
        uv pip install --python /py /tmp; \
    fi && \
    rm -rf /tmp && \
    adduser \
    --disabled-password \
    --no-create-home \
    django-user

ENV PATH="/py/bin:$PATH"

USER django-user
```

### 4. Docker Compose Specification (`docker-compose.yml`)

- **Obsolete `version` attribute**: In Docker Compose Specification v2+, the top-level `version: "3.9"` attribute is obsolete and should be omitted.
- **Passing Build Args**: Pass `DEV: true` under `build.args` for local development containers.

```yaml
services:
  app:
    build:
      context: .
      args:
        - DEV=true
      dockerfile: Dockerfile
    ports:
      - 8000:8000
    volumes:
      - ./app:/app
    command: >
      sh -c "python manage.py runserver 0.0.0.0:8000"
```

### 5. Essential CLI Commands

```bash
# Build the Docker container image using docker-compose
docker-compose build

# Bootstrap a new Django project inside the container
docker-compose run --rm app sh -c "django-admin startproject app ."

# Start and run the application service containers
docker-compose up

# Run linting checks using flake8 inside a transient container
docker-compose run --rm app sh -c "flake8"
```

### 6. GitHub Actions CI/CD Integration

Automated testing & linting workflow configured in `.github/workflows/checks.yml`:

```yaml
name: Checks

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  test-lint:
    name: Test and Lint
    runs-on: ubuntu-24.04
    steps:
      - name: Login to Docker Hub
        uses: docker/login-action@v4
        with:
          username: ${{ secrets.DOCKERHUB_USER }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}
      - name: Checkout Code
        uses: actions/checkout@v5
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v4
      - name: Test
        run: docker compose run --rm app sh -c "python manage.py test"
      - name: Lint
        run: docker compose run --rm app sh -c "flake8"
```

> Detailed CI/CD guide: See [notes/ci-cd/github-actions-guide.md](../ci-cd/github-actions-guide.md)

---

## 5 YOE Level Technical Interview Questions & Detailed Answers

### Q1: Why use Astral `uv` over standard `pip` in Docker containers, and how do you include it in a Dockerfile efficiently?

**Answer:**
`uv` is an extremely fast Python package installer and resolver written in Rust. In containerized environments, `uv` significantly reduces image build times by executing package resolution and wheel installation up to 10-100x faster than `pip`. 

The recommended way to include `uv` in a Dockerfile is multi-stage binary copying using `COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/`. This avoids needing Python or `pip` to bootstrap `uv`, keeps the image layer minimal, and ensures build reproducibility.

**Follow-up Question:** *How does layer caching work when copying `pyproject.toml` before source code?*
**Answer:** By copying `pyproject.toml` to `/tmp/` and running `uv pip install` before copying the rest of the application code (`COPY . /app`), Docker caches the dependency installation layer. Rebuilds triggered by code changes skip re-downloading and reinstalling packages.

---

### Q2: How do you handle production vs. development dependencies in a single Dockerfile without creating bloated production images?

**Answer:**
You use Docker build arguments (`ARG`) combined with shell conditional logic in the `RUN` instruction. 

In `Dockerfile`:
```dockerfile
ARG DEV=false
RUN uv venv /py && \
    if [ "$DEV" = "true" ]; then \
        uv pip install --python /py "/tmp[dev]"; \
    else \
        uv pip install --python /py /tmp; \
    fi
```

- In **Development** (`docker-compose.yml`), pass `DEV: true` under `build.args` to install dev tools like `flake8`, `pytest`, or `black`.
- In **Production** (CI/CD pipeline or production deployment), build without args or with `DEV=false`, resulting in a lean image containing strictly required runtime packages.

**Follow-up Question:** *Why use a virtual environment `/py` inside a Docker container instead of global `--system` install?*
**Answer:** Using a virtual environment isolator (like `/py`) avoids mutating system Python packages, prevents permission conflicts when switching to a non-root user (`django-user`), and makes path resolution clean via `ENV PATH="/py/bin:$PATH"`.

---

### Q3: Why is top-level `version: "3.9"` in `docker-compose.yml` obsolete in modern Docker toolchains?

**Answer:**
Docker Compose has merged into the unified **Compose Specification**. Previously, Compose files required explicit schema versioning (e.g., `version: '3.8'` or `'3.9'`) to determine feature support. Modern Docker Compose (v2.x+) automatically targets the latest Compose Specification format and ignores the `version` field, issuing deprecation warnings if present. Omission simplifies configuration files.

---

### Q4: How do you execute code quality checks (like `flake8`) inside a containerized Django application using `docker-compose`?

**Answer:**
With `flake8` installed in the dev virtualenv (`/py/bin/flake8`), you run transient containers via `docker-compose run`:

```bash
docker-compose run --rm app sh -c "flake8"
```

- `--rm` automatically cleans up the container after execution finishes.
- `sh -c "flake8"` executes `flake8` against configured paths (with exclusions defined in `.flake8` or `setup.cfg`).

**Follow-up Question:** *What files should be excluded in `.flake8` for a Django project?*
**Answer:** Auto-generated database migrations (`migrations`), bytecode caches (`__pycache__`), and entry point settings (`manage.py`, `settings.py` if third-party boilerplates produce line-length warnings).

---

### Q5: How does `.dockerignore` impact build speed and container security when using `COPY . /app`?

**Answer:**
`.dockerignore` prevents unnecessary or sensitive files from being sent in the Docker build context tarball to the Docker daemon.

Key benefits:
1. **Performance**: Excluding local virtual environments (`.venv/`), caches (`__pycache__`, `.pytest_cache`), and `.git` significantly reduces context payload size.
2. **Security**: Excludes secrets, `.env` files, and local certificates from leaking into image layers.
3. **Cache Invalidation**: Prevents changes in local test logs or `.git` commits from invalidating cached Docker build steps.
