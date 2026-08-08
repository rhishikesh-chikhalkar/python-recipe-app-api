# GitHub Actions CI/CD Architecture & Pipeline Guide

## What is GitHub Actions?

**GitHub Actions** is a native Continuous Integration and Continuous Delivery (CI/CD) automation platform built directly into GitHub. It allows developers to automate software workflows—such as building, testing, linting, security scanning, and deploying applications—automatically triggered by events in a GitHub repository.

---

## Core Components & Architecture

A GitHub Actions workflow is defined in YAML under `.github/workflows/<workflow_name>.yml`.

```
[ GitHub Repository Event (e.g. push) ]
                 │
                 ▼
      [ Workflow Execution ]
                 │
                 ▼
       [ Job: test-lint ]  ── (Runs on runner: ubuntu-24.04)
                 │
                 ├── Step 1: Docker Hub Login (docker/login-action@v3)
                 ├── Step 2: Checkout Code (actions/checkout@v4)
                 ├── Step 3: Run Unit Tests (docker-compose run --rm app sh -c "python manage.py test")
                 └── Step 4: Run Flake8 Linting (docker-compose run --rm app sh -c "flake8")
```

### Key Workflow Terms

| Component | Description | Example in `.github/workflows/checks.yml` |
| :--- | :--- | :--- |
| **Workflow** | Configured automated process stored in `.github/workflows/`. | `name: Checks` |
| **Event (`on`)** | Specific activity that triggers workflow execution. | `on: [push]` |
| **Job (`jobs`)** | A set of steps executing on a fresh virtual machine runner. | `test-lint:` |
| **Runner (`runs-on`)** | Server hosted by GitHub (or self-hosted) running job steps. | `runs-on: ubuntu-24.04` |
| **Step (`steps`)** | Individual task that can run shell commands or reusable actions. | `- name: Test` |
| **Action (`uses`)** | Reusable plugin provided by GitHub or community (Docker, Actions). | `actions/checkout@v4` |
| **Secrets (`${{ secrets.* }}`)** | Encrypted configuration values stored securely in GitHub. | `${{ secrets.DOCKERHUB_USER }}` |

---

## Reference Workflow Pipeline

Below is the production-grade workflow configured in `.github/workflows/checks.yml`:

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

---

## How It Works Step-by-Step

1. **Trigger Phase**: The developer pushes code to GitHub (`git push origin main`). GitHub detects the `push` event and initializes the `Checks` workflow.
2. **Runner Allocation**: GitHub provisions a clean virtual machine running `ubuntu-24.04`.
3. **Authentication**: `docker/login-action@v3` authenticates the runner with Docker Hub using encrypted repository secrets (`DOCKERHUB_USER` and `DOCKERHUB_TOKEN`) to avoid rate limiting on image pulls (`python:3.9-alpine3.13` and `ghcr.io/astral-sh/uv`).
4. **Code Checkout**: `actions/checkout@v4` clones the exact commit SHA onto the runner workspace.
5. **Containerized Testing**: `docker-compose run --rm app sh -c "python manage.py test"` builds/reuses the container image and runs Django unit tests.
6. **Code Quality Linting**: `docker-compose run --rm app sh -c "flake8"` runs static code analysis inside the container virtual environment.
7. **Cleanup**: The transient containers are automatically removed (`--rm`), and the VM instance is destroyed post-execution.

---

## 5 YOE Level Technical Interview Questions & Detailed Answers

### Q1: What is GitHub Actions, and how does its event-driven architecture execute CI/CD workflows?

**Answer:**
GitHub Actions is an event-driven CI/CD platform integrated into GitHub repositories. Workflows are defined using YAML declarations inside `.github/workflows/`. 

When a registered event occurs (e.g., `push`, `pull_request`, `release`, `schedule`), GitHub dispatches the event to a runner manager. The runner manager provisions an isolated VM (or container runner), checks out the codebase, and executes jobs in parallel (or sequentially if `needs:` dependencies are specified). Each job consists of atomic steps executed linearly within the runner's shell environment.

**Follow-up Question:** *What happens if one step in a job fails?*
**Answer:** By default, if a step exits with a non-zero status code, execution of subsequent steps in that job halts immediately, failing the job and sending notifications unless `continue-on-error: true` or conditional steps like `if: always()` are configured.

---

### Q2: Why run unit tests and linting inside Docker containers during GitHub Actions instead of directly on the runner host?

**Answer:**
Running tests and linters inside Docker containers guarantees **environment parity**:
1. **Consistency**: The exact same Python runtime (Alpine 3.13 / Python 3.9), C-libraries, and `uv`-managed dependencies are used in local development, CI/CD, and production.
2. **Isolation**: Avoids relying on pre-installed tools or Python versions on the GitHub runner VM (`ubuntu-24.04`), eliminating "works on CI but fails locally" discrepancies.
3. **Zero Configuration Overhead**: The runner VM only needs Docker and Docker Compose installed; project dependencies do not need to be manually installed on the host.

---

### Q3: How do GitHub Secrets work, and what security practices prevent secret leaks in pull requests?

**Answer:**
GitHub Secrets are encrypted environment variables stored in repository or organization settings using libsodium public-key encryption. In workflows, they are accessed via `${{ secrets.SECRET_NAME }}` and masked automatically in log outputs (`***`).

**Security Best Practices:**
1. **Pull Request Restrictions**: By default, secrets are **not** exposed to workflows triggered by pull requests from forks to prevent untrusted code from printing secrets.
2. **Least Privilege**: Grant minimal necessary permissions to tokens (e.g. read-only Docker Hub tokens or scoping `GITHUB_TOKEN` permissions).
3. **Environment Secrets**: Use GitHub Environments with required reviewers for sensitive production deployment credentials.

---

### Q4: How can Docker layer caching be optimized in GitHub Actions to reduce CI pipeline execution time?

**Answer:**
To prevent re-downloading base images and rebuilding virtual environments on every commit:
1. **`docker/setup-buildx-action` & `cache-from` / `cache-to`**: Use Docker Buildx with GitHub Actions Cache backend (`type=gha`).
   ```yaml
   - name: Build and push
     uses: docker/build-push-action@v5
     with:
       cache-from: type=gha
       cache-to: type=gha,mode=max
   ```
2. **`actions/cache` for `uv`**: Cache `uv` cache directory (`~/.cache/uv`) across workflow runs.
3. **Order of Dockerfile Layers**: Place stable layers (`COPY pyproject.toml /tmp/` and `uv pip install`) before volatile layers (`COPY . /app`) to leverage cached build layers.

---

### Q5: What is the difference between `docker-compose run` vs `docker-compose exec` in a CI/CD environment?

**Answer:**
- `docker-compose run`: Creates a **new, one-off container** from the service image, executes the specified command, and exits. Ideal for non-daemon tasks like running unit tests (`python manage.py test`), database migrations (`migrate`), or linters (`flake8`) in fresh isolated containers.
- `docker-compose exec`: Executes a command inside an **already running container**. In CI/CD pipelines where services are started detached (`docker-compose up -d`), `exec` can be used to run commands inside active services without spinning up new containers.
