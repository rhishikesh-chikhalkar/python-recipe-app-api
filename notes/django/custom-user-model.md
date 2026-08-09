# Django Custom User Model: AbstractBaseUser & PermissionsMixin

## Overview

Django provides a robust built-in authentication system (`django.contrib.auth`).
While Django includes a default `User` model, production applications almost
always require a custom user model to support alternate login identifiers (such as
email), custom fields, or tailored role mechanisms.

Setting `AUTH_USER_MODEL` in `settings.py` before running initial migrations is a
fundamental Django best practice.

---

## Core Architecture & Components

```
                    +--------------------------------+
                    |       AbstractBaseUser         |
                    | (Authentication & Password)    |
                    +--------------------------------+
                                    |
                                    +-----------------------+
                                    |                       |
                    +--------------------------------+      |
                    |        PermissionsMixin        |      |
                    | (Groups & Permissions Schema)  |      |
                    +--------------------------------+      |
                                    |                       |
                                    v                       v
                    +------------------------------------------------+
                    |                  Custom User                   |
                    |         (e.g., core.models.User)               |
                    +------------------------------------------------+
                                    ^
                                    |
                    +------------------------------------------------+
                    |                BaseUserManager                 |
                    |       (Helper methods for creation)            |
                    +------------------------------------------------+
```

### 1. AbstractBaseUser

`django.contrib.auth.models.AbstractBaseUser` provides the minimum core logic
required for a functioning user model in Django:

- **Fields Included**: `password`, `last_login`, and `is_active` (via default
  class behavior).
- **Password Management**: Includes hashing, check methods (`set_password`,
  `check_password`), and password reset token generation helpers.
- **Required Class Attributes**:
  - `USERNAME_FIELD`: String naming the field used as the unique identifier
    (e.g., `'email'`).
  - `REQUIRED_FIELDS`: List of field names prompted when creating a user via
    `createsuperuser`.
  - `is_active`: Boolean attribute (or model field) determining if the account
    is active.

### 2. PermissionsMixin

`django.contrib.auth.models.PermissionsMixin` supplies the full Django
permissions and group architecture needed for Django Admin and permission
checking:

- **Fields Included**:
  - `is_superuser`: Boolean indicating full permissions without explicit
    assignment.
  - `groups`: ManyToMany relationship to `django.contrib.auth.models.Group`.
  - `user_permissions`: ManyToMany relationship to
    `django.contrib.auth.models.Permission`.
- **Methods Included**:
  - `has_perm(perm, obj=None)`: Checks if user has a specific permission
    string.
  - `has_module_perms(package_name)`: Checks if user has permissions for a
    specific app module.

### 3. AbstractUser vs. AbstractBaseUser

| Feature | AbstractUser | AbstractBaseUser |
| :--- | :--- | :--- |
| **Base Use Case** | Adding fields to default user | Full control over schema & fields |
| **Default Fields** | Includes `username`, `email`, etc. | Minimal: `password` and `last_login` |
| **Permissions** | Pre-built via `PermissionsMixin` | Must inherit `PermissionsMixin` |
| **Flexibility** | Retains `username` requirement | Can remove `username` field |

---

## Production Implementation Pattern

### 1. Manager (`BaseUserManager`) and Model Definition

```python
from django.contrib.auth.models import (
    AbstractBaseUser,
    BaseUserManager,
    PermissionsMixin,
)
from django.db import models


class UserManager(BaseUserManager):
    """Manager for custom user model using email as identifier."""

    def create_user(self, email, password=None, **extra_fields):
        """Create, save, and return a new user."""
        if not email:
            raise ValueError("User must have an email address.")
        email = self.normalize_email(email)
        user = self.model(email=email, **extra_fields)
        user.set_password(password)
        user.save(using=self._db)
        return user

    def create_superuser(self, email, password):
        """Create, save, and return a new superuser."""
        user = self.create_user(email, password)
        user.is_staff = True
        user.is_superuser = True
        user.save(using=self._db)
        return user


class User(AbstractBaseUser, PermissionsMixin):
    """Custom user model supporting email authentication."""

    email = models.EmailField(max_length=255, unique=True)
    name = models.CharField(max_length=255)
    is_active = models.BooleanField(default=True)
    is_staff = models.BooleanField(default=False)

    objects = UserManager()

    USERNAME_FIELD = "email"
```

### 2. Setting `AUTH_USER_MODEL`

In `settings.py`:

```python
AUTH_USER_MODEL = "core.User"
```

### 3. Referencing the User Model Across the Codebase

Always avoid importing the custom `User` model directly in non-model files or
relationships.

- **For Foreign Keys / Model Relations**:
  ```python
  from django.conf import settings

  class Recipe(models.Model):
      user = models.ForeignKey(
          settings.AUTH_USER_MODEL,
          on_delete=models.CASCADE,
      )
  ```
- **For Runtime Code / Views / Utilities**:
  ```python
  from django.contrib.auth import get_user_model

  User = get_user_model()
  user = User.objects.get(email="user@example.com")
  ```

---

## Common Pitfalls & Best Practices

1. **Changing `AUTH_USER_MODEL` Mid-Project**:
   - Creating a custom user model after running `python manage.py migrate` for
     the first time can break foreign keys to `auth.User`.
   - **Fix**: Define a custom user model at project initialization, even if it
     just inherits from `AbstractUser` initially.
2. **Missing `PermissionsMixin`**:
   - Inheriting only from `AbstractBaseUser` without `PermissionsMixin` will
     cause Django Admin or permission checks (`user.has_perm()`) to fail with
     `AttributeError` or missing fields.
3. **Forgetting `normalize_email()`**:
   - Failing to normalize emails in `create_user` leads to duplicate accounts
     due to casing differences (`User@Example.com` vs `user@example.com`).
4. **Hardcoding User Model Imports**:
   - Direct imports like `from core.models import User` create tight coupling
     and circular import risks. Use `settings.AUTH_USER_MODEL` in models and
     `get_user_model()` in application logic.

---

## Authoritative References

- [Django Docs: Customizing Authentication in Django][auth-customizing]
- [Django Docs: Substituting a Custom User Model][substituting-user]
- [Django Docs: AbstractBaseUser Reference][abstract-base-user]

[auth-customizing]:
  https://docs.djangoproject.com/en/5.0/topics/auth/customizing/
[substituting-user]:
  https://docs.djangoproject.com/en/5.0/topics/auth/customizing/#substituting-a-custom-user-model
[abstract-base-user]:
  https://docs.djangoproject.com/en/5.0/topics/auth/
  customizing/#django.contrib.auth.models.AbstractBaseUser

---

## Interview Questions & Answers (5+ YOE Level)

### 1. Conceptual / Architecture
**Q: What is the architectural difference between inheriting from `AbstractUser` vs.**
**`AbstractBaseUser` in Django, and when would you choose one over the other in an**
**enterprise project?**

**Answer:**
`AbstractUser` provides a complete, ready-to-use user model containing standard Django
fields (`username`, `first_name`, `last_name`, `email`, `is_staff`, etc.) along with
built-in permissions via `PermissionsMixin`. It is best used when you want to retain
Django's default `username`-based fields but add extra attributes (e.g., `phone_number`,
`profile_picture`).

`AbstractBaseUser` is a barebones abstract class that only provides password handling
(`password`, `last_login`, hashing utilities) and session auth methods. It requires the
developer to explicitly define all fields, set `USERNAME_FIELD`, create a custom
`BaseUserManager`, and mix in `PermissionsMixin` if admin/permissions support is needed.

In enterprise applications, `AbstractBaseUser` is preferred when:
- Email or UUID is required as the primary authentication identifier instead of `username`.
- Strict schema minimalism or custom compliance attributes are required without legacy
  unused fields like `first_name`/`last_name`.

*Follow-up question interviewer might ask:* What happens if you forget to include
`PermissionsMixin` when inheriting from `AbstractBaseUser`?

---

### 2. Scenario / Troubleshooting
**Q: You are tasked with migrating an existing production Django system with millions of**
**users from Django's default `auth.User` to a custom `core.User` model derived from**
**`AbstractBaseUser`. How do you execute this safely without downtime or data loss?**

**Answer:**
Migrating `AUTH_USER_MODEL` on an existing database mid-lifecycle cannot be done via a
simple `makemigrations` step because Django's foreign key constraints across
`auth_permission`, `auth_group`, and app models point to `auth_user`.

The safe production migration strategy involves:
1. **Schema Creation**: Create the new `core_user` table in database without pointing
   `AUTH_USER_MODEL` to it immediately.
2. **Dual-Write / ETL Pipeline**: Deploy code that syncs user creations/updates to both
   `auth_user` and `core_user`, or run a zero-downtime ETL script to copy all existing
   user data and hashed passwords to `core_user`.
3. **Foreign Key Pointer Migration**: Write custom SQL or Data Migrations to re-point
   existing foreign keys in dependent tables (e.g., `orders`, `profiles`) from
   `auth_user.id` to `core_user.id`.
4. **App Config Update**: Switch `AUTH_USER_MODEL = 'core.User'` in settings, update fake
   migration state in Django's `django_migrations` table if necessary, and verify Django
   Admin login.

*Follow-up question interviewer might ask:* How do password hashes migrate between models?
Do users need to reset their passwords?

*Answer:* Password hashes stored in `auth_user.password` use Django's PBKDF2/Argon2 format
and can be copied directly into `core_user.password` without requiring password resets.

---

### 3. Practical / Implementation
**Q: Why does Django require `BaseUserManager` when defining a custom user model with**
**`AbstractBaseUser`, and what are the critical steps inside `create_user` and `create_superuser`?**

**Answer:**
`AbstractBaseUser` does not come with a default model manager (`objects`), because the
manager needs to know which field serves as the username identifier (`USERNAME_FIELD`) and
how to properly instantiate the user instance.

The critical steps inside `BaseUserManager`:
1. **Validation**: Validate required fields (e.g., checking `if not email:`).
2. **Email Normalization**: Call `self.normalize_email(email)` to lower-case the domain
   part of the email address.
3. **Model Instantiation**: Instantiate `user = self.model(email=email, **extra_fields)`.
4. **Password Hashing**: Call `user.set_password(password)` (never store raw passwords!).
5. **Database Persistence**: Call `user.save(using=self._db)` and return user object.
6. **Superuser Execution**: In `create_superuser`, invoke `create_user` and explicitly set
   `is_staff=True` and `is_superuser=True`.

*Follow-up question interviewer might ask:* Why is `using=self._db` passed to `user.save()`
inside `BaseUserManager` methods?

*Answer:* It ensures the user object is saved to the database specified by multi-database
routing rules rather than hardcoding the default database.

---

### 4. System Design / Security
**Q: How does Django's `PermissionsMixin` work under the hood with RBAC (Role-Based Access**
**Control) and how would you extend it for a multi-tenant enterprise system?**

**Answer:**
`PermissionsMixin` integrates two Django models: `Group` (roles) and `Permission` (granular
actions formatted as `<app>.<action>_<model>`).
When `user.has_perm('app.view_recipe')` is called:
1. If `is_superuser` is `True`, it immediately returns `True`.
2. Otherwise, Django queries `user.user_permissions` (direct permissions) and
   `user.groups.permissions` (inherited group permissions) and caches them on user instance.

In a multi-tenant system (e.g., SaaS where users belong to organizations):
- Django's built-in global permissions model is insufficient because permissions must be
  scoped per organization tenant.
- **Solution**: Extend `PermissionsMixin` or create a custom backend (`AUTHENTICATION_BACKENDS`)
  that overrides `has_perm(user_obj, perm, obj=None)`, evaluating tenant ownership via
  `obj` or tenant context headers.

*Follow-up question interviewer might ask:* How do custom authentication backends work in
Django when `user.has_perm()` is executed?

---

### 5. Code Review / Edge Case Identification
**Q: Spot the security flaws or bugs in the following custom User implementation:**

```python
class UserManager(BaseUserManager):
    def create_user(self, email, password, **extra_fields):
        user = self.model(email=email, password=password, **extra_fields)
        user.save()
        return user

class User(AbstractBaseUser):
    email = models.CharField(max_length=255)
    is_staff = models.BooleanField(default=True)
    USERNAME_FIELD = 'email'
```

**Answer / Flaws:**
1. **Plaintext Password Storage**: `password` is passed directly into `self.model()`
   without calling `user.set_password(password)`. Passwords will be saved in plaintext!
2. **Missing Email Normalization**: `email` is not normalized using
   `self.normalize_email(email)`.
3. **Invalid Email Field & Non-Unique**: `email` is a `CharField` instead of
   `EmailField`, and lacks `unique=True`. Non-unique username fields break auth lookup.
4. **Security Risk (`is_staff=True` by default)**: Every newly created user becomes a
   staff member with access to admin interface by default.
5. **Missing `PermissionsMixin`**: Inherits from `AbstractBaseUser` without
   `PermissionsMixin`, breaking `is_superuser` checks, group assignments, and admin.
6. **Missing `create_superuser`**: The manager does not implement `create_superuser`,
   preventing `python manage.py createsuperuser` from working.
