# Custom Django Management Commands & Docker Database Synchronization

## Overview

This guide details the design, implementation, and testing of custom Django management commands (specifically `wait_for_db`) to resolve race conditions between Docker container startup order and PostgreSQL database readiness. It also covers bootstrapping Django apps within a containerized environment (`docker-compose run`).

---

## Key Architecture & Setup Concepts

### 1. Bootstrapping Django Apps in Docker

To keep file permissions consistent and run commands inside the configured container virtualenv `/py`, Django apps should be generated using `docker-compose run`:

```bash
docker-compose run --rm app sh -c "python manage.py startapp core"
```

- `--rm`: Automatically removes the transient container upon exit.
- `startapp core`: Generates standard Django app directory structure inside `/app/core`.
- `INSTALLED_APPS`: Register `"core"` in `app/settings.py`.

### 2. The Database Connection Race Condition in Docker

In `docker-compose.yml`, `depends_on` ensures that the `db` container starts before the `app` container. However, `depends_on` only checks that the container process is running, **not** that PostgreSQL is ready to accept TCP network connections.

PostgreSQL startup steps include:
1. Container initialization & memory allocation.
2. Database cluster initialization / WAL replay.
3. Socket binding and listening on port `5432`.

If Django attempts database migrations or starts the server (`runserver`) while PostgreSQL is still initializing, Django throws an `OperationalError` or `Psycopg2Error`.

### 3. Custom Management Command: `wait_for_db`

Directory layout for custom management commands in Django:

```
app/
└── core/
    ├── management/
    │   ├── __init__.py
    │   └── commands/
    │       ├── __init__.py
    │       └── wait_for_db.py
```

Implementation (`app/core/management/commands/wait_for_db.py`):

```python
"""
Django commands to wait for db connection.
"""

import time

from psycopg2 import OperationalError as Psycopg2OpError

from django.core.management.base import BaseCommand
from django.db.utils import OperationalError


class Command(BaseCommand):
    """Django command to wait for database."""

    def handle(self, *args, **options):
        """Entrypoint for command."""
        self.stdout.write("Waiting for database...")
        db_up = False
        while db_up is False:
            try:
                self.check(databases=["default"])
                db_up = True
            except (Psycopg2OpError, OperationalError):
                self.stdout.write("Database unavailable, waiting 1 second...")
                time.sleep(1)

        self.stdout.write(self.style.SUCCESS("Database available!"))
```

- `self.check(databases=["default"])`: Built-in Django command method that tests database connection health against configured database aliases.
- Exception handling: Catches both `Psycopg2OpError` (driver layer) and `OperationalError` (Django ORM layer).

### 4. Unit Testing Custom Commands with Mock (`unittest.mock.patch`)

Unit testing database retry logic without delaying test runs requires mocking `time.sleep` and `Command.check`.

Test implementation (`app/core/tests/test_command.py`):

```python
"""
Test custom django management commands.
"""

from unittest.mock import patch

from django.core.management import call_command
from django.db.utils import OperationalError
from django.test import SimpleTestCase
from psycopg2 import OperationalError as Psycopg2Error


@patch("core.management.commands.wait_for_db.Command.check")
class CommandTests(SimpleTestCase):
    """Test commands."""

    def test_wait_for_db_ready(self, patched_check):
        """Test waiting for database if database is ready."""
        patched_check.return_value = True

        call_command("wait_for_db")

        patched_check.assert_called_once_with(databases=["default"])

    @patch("time.sleep")
    def test_wait_for_db_delay(self, patched_sleep, patched_check):
        """Test waiting for database when getting OperationalError."""
        patched_check.side_effect = (
            [Psycopg2Error] * 2 + [OperationalError] * 3 + [True]
        )

        call_command("wait_for_db")

        self.assertEqual(patched_check.call_count, 6)
        patched_check.assert_called_with(databases=["default"])
```

#### Detailed Breakdown of Mocking & Patching Mechanics

- **Class-Level `@patch`**: `@patch("core.management.commands.wait_for_db.Command.check")` intercepts `Command.check` for all test methods in `CommandTests`. `patched_check` is injected as a parameter into each test method.
- **Method-Level `@patch`**: `@patch("time.sleep")` replaces `time.sleep` with a `MagicMock` during `test_wait_for_db_delay`. This avoids real `1` second sleep pauses, reducing execution time from ~5s to 2ms.
- **Decorator Parameter Ordering**: Python applies stacked decorators from bottom up. `patched_sleep` (inner decorator `@patch("time.sleep")`) is passed first, followed by `patched_check` (outer class decorator).
- **`return_value`**: Sets a static return value (`True`) whenever `patched_check` is called.
- **`side_effect`**: Configured with a sequence `[Psycopg2Error] * 2 + [OperationalError] * 3 + [True]`.
  - Invocations 1 & 2 raise `Psycopg2Error`.
  - Invocations 3, 4, & 5 raise `OperationalError`.
  - Invocation 6 returns `True`, breaking the `while db_up is False` loop.
- **`assert_called_once_with` vs `assert_called_with`**:
  - `assert_called_once_with(databases=["default"])`: Asserts the mock was called **exactly once** with `databases=["default"]`.
  - `assert_called_with(databases=["default"])`: Asserts the **most recent** call was made with `databases=["default"]`.
- **`call_count`**: Verifies `patched_check` was called exactly 6 times (`self.assertEqual(patched_check.call_count, 6)`).

> Deep Dive Guide: See [notes/python/unittest-mock-and-patch.md](../python/unittest-mock-and-patch.md)

---

## 5 YOE Level Technical Interview Questions & Detailed Answers

### Q1: Why does Docker Compose `depends_on` fail to prevent Django database connection errors during container startup?

**Answer:**
`depends_on` controls container startup and shutdown order, but it operates purely at the container engine state level. It considers a service "started" as soon as the container process starts running. 

Relational databases like PostgreSQL require seconds to initialize shared memory, load configuration, perform recovery/WAL checks, and begin listening on network sockets. If Django executes `python manage.py migrate` or `runserver` before socket binding finishes, connection attempts fail with `OperationalError`. 

**Follow-up Question:** *How can Docker Compose native healthchecks address this issue?*
**Answer:** Docker Compose v2+ supports service `healthcheck` definitions and `depends_on.<service>.condition: service_healthy`. While container healthchecks are useful, implementing application-level retry logic (`wait_for_db`) provides defense-in-depth across Kubernetes, ECS, and standalone Docker deployments.

---

### Q2: What is the difference between `SimpleTestCase` and `TestCase` in Django test suite architecture?

**Answer:**
- `SimpleTestCase`: Disables database transaction setup and teardown. It is fast and ideal for testing pure functions, utility classes, and commands where database interaction is mocked.
- `TestCase`: Wraps each test method in a database transaction and rolls it back after execution, ensuring database state isolation between tests.

Using `SimpleTestCase` for unit tests that mock DB calls (`wait_for_db`) saves execution overhead and speeds up CI/CD pipeline runs.

---

### Q3: How does `unittest.mock.patch` handle argument passing when using multiple stacked decorators?

**Answer:**
When stacking multiple `@patch` decorators on a test method, Python applies decorators from the bottom up (closest to function first). Consequently, mock objects are passed to the test function parameters in top-to-bottom order.

Example:
```python
@patch("core.management.commands.wait_for_db.Command.check")
@patch("time.sleep")
def test_wait_for_db_delay(self, patched_sleep, patched_check): ...
```
`@patch("time.sleep")` is closest to `def`, so `patched_sleep` is passed as the first parameter after `self`, and `patched_check` is passed second.

---

### Q4: Why is `psycopg2.OperationalError` caught separately from `django.db.utils.OperationalError`?

**Answer:**
During Django startup and DB connection pooling, errors can originate at two distinct abstraction layers:
1. **Driver Layer (`psycopg2.OperationalError`)**: Raised when the low-level C-extension socket connection attempt to PostgreSQL fails.
2. **Framework Layer (`django.db.utils.OperationalError`)**: Raised by Django's ORM database wrapper when handling backend errors.

Catching both exceptions ensures robust fallback regardless of whether the connection fails at the TCP socket layer or Django connection wrapper layer.

---

### Q5: How do you register a custom Django management command so `python manage.py <command_name>` detects it?

**Answer:**
Django uses convention-based module discovery:
1. Create a `management/` package with an `__init__.py` file inside an app listed in `INSTALLED_APPS`.
2. Create a `commands/` sub-package with an `__init__.py` file inside `management/`.
3. Add a Python module named `<command_name>.py` (e.g. `wait_for_db.py`) containing a subclass of `django.core.management.base.BaseCommand` with a defined `handle(self, *args, **options)` method.

Once registered in `INSTALLED_APPS`, Django automatically exposes `python manage.py wait_for_db`.
