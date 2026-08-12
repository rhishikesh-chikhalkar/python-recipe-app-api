# Python Unit Testing: Mocking, Patching & `side_effect` Deep Dive

## Overview

This guide provides a comprehensive technical breakdown of Python's `unittest.mock` module, detailing `Mock`, `MagicMock`, `@patch`, target resolution rules, argument injection order, `return_value`, and the versatile behavior of `side_effect`.

---

## Key Architecture & Setup Concepts

### 1. Core Mocking Objects: `Mock` vs `MagicMock`

- **`Mock`**: The base class for mocking objects in Python. It records calls, arguments, and access to attributes. Un-stubbed attributes automatically generate child `Mock` objects.
- **`MagicMock`**: A subclass of `Mock` that comes pre-configured with default implementations for Python magic/dunder methods (e.g. `__len__`, `__enter__`, `__exit__`, `__iter__`, `__getitem__`).

```python
from unittest.mock import MagicMock

# MagicMock supports context manager protocols out of the box
mock_file = MagicMock()
mock_file.__enter__.return_value = "file contents"

with mock_file as f:
    assert f == "file contents"
```

### 2. Configuring Mock Responses: `return_value` vs `side_effect`

#### `return_value`

Defines a static, fixed value returned on **every** call to the mock:

```python
from unittest.mock import Mock

mock_func = Mock()
mock_func.return_value = True

assert mock_func() is True
assert mock_func("any", arg="value") is True  # Always returns True
```

#### `side_effect`

`side_effect` allows dynamic behavior upon invocation and can be configured in 3 distinct ways:

##### A. Sequence / Iterable (Iterating Return Values & Exceptions)

When assigned an iterable (list, tuple, generator), each invocation of the mock consumes the next element:
- If the element is an **exception class or instance**, it is **raised**.
- If the element is a **normal value**, it is **returned**.

```python
from unittest.mock import Mock
from django.db.utils import OperationalError
from psycopg2 import OperationalError as Psycopg2Error

patched_check = Mock()
# First 2 calls raise Psycopg2Error, next 3 raise OperationalError, 6th returns True
patched_check.side_effect = [
    Psycopg2Error,
    Psycopg2Error,
    OperationalError,
    OperationalError,
    OperationalError,
    True,
]

try:
    patched_check()  # Call 1: Raises Psycopg2Error
except Psycopg2Error:
    pass

assert (
    patched_check() is Psycopg2Error
)  # If class object is in list without raise context
```

> **Important Distinction**: In `side_effect` lists, if an exception *class* (like `Psycopg2Error`) is passed, `unittest.mock` automatically instantiates and **raises** it. If a normal object or boolean is passed, it is returned.

##### B. Exception Class or Instance (Always Raise)

Assigning a single exception class or instance causes **every** invocation to raise that exception:

```python
mock_db = Mock()
mock_db.side_effect = OperationalError("Database connection failed")

# Every call raises OperationalError
```

##### C. Custom Callable (Dynamic Computation)

Assigning a function or lambda allows computing return values dynamically based on input parameters:

```python
def dynamic_response(database_alias):
    if database_alias == "default":
        return True
    raise ValueError(f"Unknown database {database_alias}")


mock_check = Mock(side_effect=dynamic_response)
assert mock_check("default") is True
```

### 3. Assertions on Mocks

`unittest.mock` provides specialized assertion methods to verify interaction contracts:

| Assertion Method | Technical Description |
| :--- | :--- |
| `mock.assert_called_once_with(*args, **kwargs)` | Asserts mock was called **exactly once** with specified arguments. |
| `mock.assert_called_with(*args, **kwargs)` | Asserts the **most recent** call was made with specified arguments. |
| `mock.call_count` | Returns total integer count of mock invocations. |
| `mock.called` | Boolean indicating whether mock was called at least once. |
| `mock.assert_has_calls([call(...), ...])` | Asserts mock was called with a specific sequence of calls. |

---

## Patching Mechanics (`unittest.mock.patch`)

### 1. Target Lookup Resolution Rule ("Patch Where Used")

The most critical rule of patching: **Patch the object where it is imported and used, NOT where it is defined.**

#### Scenario Example

Suppose `wait_for_db.py` contains:

```python
# app/core/management/commands/wait_for_db.py
from django.core.management.base import BaseCommand


class Command(BaseCommand):
    def handle(self, *args, **options):
        self.check(databases=["default"])
```

- **Incorrect Patch**: `@patch("django.core.management.base.BaseCommand.check")` (Patching definition module).
- **Correct Patch**: `@patch("core.management.commands.wait_for_db.Command.check")` (Patching usage target).

### 2. Class-Level vs Method-Level Patching & Argument Ordering

Decorators are evaluated from the **bottom up** (inner to outer), but mock parameters are injected from **top to bottom**.

```python
from unittest.mock import patch
from django.test import SimpleTestCase


# Class-level patch (Outer decorator -> 2nd parameter)
@patch("core.management.commands.wait_for_db.Command.check")
class CommandTests(SimpleTestCase):
    # Method-level patch (Inner decorator -> 1st parameter)
    @patch("time.sleep")
    def test_wait_for_db_delay(self, patched_sleep, patched_check):
        """
        patched_sleep corresponds to @patch("time.sleep") [Method-level]
        patched_check corresponds to @patch("Command.check") [Class-level]
        """
        ...
```

---

## 5 YOE Level Technical Interview Questions & Detailed Answers

### Q1: How does `unittest.mock.patch` work under the hood, and what happens when the context exits?

**Answer:**
`patch` acts as a context manager and decorator. Upon entering (`__enter__`), it uses Python's `setattr()` to dynamically replace the target attribute on the specified module/class with a `MagicMock` instance. Upon exiting (`__exit__`), it invokes `setattr()` again to restore the original attribute reference stored in `self.temp_original`.

This guarantees test isolation and prevents mock leakage into subsequent test runs.

---

### Q2: What is the difference between `mock.return_value` and `mock.side_effect`, and what happens if both are set?

**Answer:**
- `return_value`: Specifies a static value returned every time the mock is called.
- `side_effect`: Specifies an iterable of values/exceptions, a single exception, or a callable for dynamic execution.

If **both** are set on a mock instance, **`side_effect` takes precedence**. `return_value` is ignored unless `side_effect` returns `DEFAULT` (`unittest.mock.DEFAULT`).

---

### Q3: Why does patching `time.sleep` in unit tests prevent test execution delays?

**Answer:**
`time.sleep(seconds)` blocks the current thread execution for the specified duration. In unit tests for retry loops (like database polling), executing real `time.sleep(1)` inside a loop running 5 retries adds 5 seconds of latency per test run.

By applying `@patch("time.sleep")`, `time.sleep` is replaced with a `MagicMock` that returns immediately (`None`) while recording that `sleep(1)` was called, reducing test suite execution time from 5 seconds to 2 milliseconds.

---

### Q4: How do you handle mocking a context manager (`with` statement) using `MagicMock`?

**Answer:**
A context manager requires implementing `__enter__` and `__exit__`. `MagicMock` automatically supports this protocol:

```python
mock_cm = MagicMock()
mock_cm.__enter__.return_value = "resource"
mock_cm.__exit__.return_value = False  # Do not suppress exceptions

with mock_cm as res:
    assert res == "resource"

mock_cm.__enter__.assert_called_once()
mock_cm.__exit__.assert_called_once()
```

---

### Q5: What is the "Patch Where Used" principle and why does patching `datetime.now` directly on the `datetime` module often fail?

**Answer:**
If a module imports `datetime` using `from datetime import datetime`, it creates a local reference to the `datetime` class inside that module's namespace. 

Patching `@patch("datetime.datetime.now")` mutates the global `datetime` module, but the target module retains its imported local reference. Patching must target the importing module's namespace: `@patch("app.utils.datetime")`.

Furthermore, built-in C-extension types like `datetime.datetime` are immutable in CPython, requiring patching at the module import location rather than mutating the type object directly.
