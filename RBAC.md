# Role-Based Access Control (RBAC)

This project uses a small, explicit role layer on top of the existing
`is_superuser` flag. Roles gate both the backend API and the React UI so a user
cannot reach a screen or action they are not allowed to.

## Roles

| Role    | Description                                                        |
|---------|--------------------------------------------------------------------|
| `admin` | Full access to user management and settings.                       |
| `manager`| Can list users and view metrics, but cannot change global settings.|
| `member`| Can only access their own profile and basic app features.          |

## Permission Matrix

| Action               | admin | manager | member |
|----------------------|:-----:|:-------:|:------:|
| List all users       |   ✓   |    ✓    |   ✗    |
| Create user          |   ✓   |    ✗    |   ✗    |
| Update / delete any user | ✓ |    ✗    |   ✗    |
| View metrics         |   ✓   |    ✓    |   ✗    |
| Update own profile   |   ✓   |    ✓    |   ✓    |