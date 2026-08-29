# ADR-0001: Role-based access control with FastAPI dependencies

## Context

The template originally only had a boolean `is_superuser` flag guarding admin
endpoints. The assignment requires three roles (`admin`, `manager`, `member`)
that gate both the API and the React UI, with clear, maintainable, and
consistent enforcement.

## Options considered

1. **Middleware**: Inspect the token in a global middleware and store roles on
   the request. Simple to add globally, but coarse-grained and makes per-route
   policy opaque and harder to unit test.

2. **Route-level dependencies** (`require_roles`)**: FastAPI's native dependency
   injection. Each route declares its allowed roles on the decorator, matching
   the template's existing `get_current_active_superuser` pattern.

3. **A separate policy/permission service**: A central map of
   permission -> roles queried manually per handler. More extensible for large
   systems, but heavier than needed here.

## Decision

Use **route-level FastAPI dependencies**. A single `require_roles(*roles)`
factory (in `app/api/deps.py`) builds a dependency that reads the authenticated
user's `role` and returns `403` if it is not allowed. Routes opt in by listing
their roles, so the permission model is visible directly at each endpoint.

On the frontend, a single helper in `frontend/src/lib/permissions.ts` mirrors the
same matrix and is used for navigation and route gating. The backend dependency
remains the source of truth; the frontend hides/forbids routes as a UX
convenience.

`role` is the source of truth for RBAC, while `is_superuser` is retained as a
derived convenience flag: whenever a user's role is `admin`, the backend sets
`is_superuser` to `True` (see `crud.create_user` / `crud.update_user`), and
clears it for other roles. The UI exposes a 3-option Role selector
(`admin`/`manager`/`member`) in both the Add and Edit user dialogs instead of a
superuser checkbox, and the admin table displays the actual role badge.

## Consequences

- Backend enforcement is centralized and testable (`test_authorization.py`).
- Frontend and backend share one documented matrix, keeping behavior consistent.
- Because RBAC denials return `403`, the frontend treats HTTP `401` (not
  authenticated) and `403` (authenticated but forbidden) differently: only `401`
  triggers a sign-out in `main.tsx`, while `403` surfaces the error to the user
  (a toast or the Forbidden page) without logging them out.
- If the app grows many fine-grained permissions, this can evolve toward a
  permission-based helper without changing the route-decorator pattern.
