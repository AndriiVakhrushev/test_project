import type { Role, UserPublic } from "@/client"

// Central place for the RBAC matrix so the UI mirrors backend enforcement:
//   Permission           admin   manager   member
//   users.list              ✓        ✓        ✗
//   users.create            ✓        ✗        ✗
//   users.update            ✓        ✗        ✗
//   metrics.view            ✓        ✓        ✗
//   (own profile)           ✓        ✓        ✓

export type Permission =
  | "users.list"
  | "users.create"
  | "users.update"
  | "users.delete"
  | "metrics.view"

const ROLE_PERMISSIONS: Record<Role, readonly Permission[]> = {
  admin: [
    "users.list",
    "users.create",
    "users.update",
    "users.delete",
    "metrics.view",
  ],
  manager: ["users.list", "metrics.view"],
  member: [],
}

export function can(
  user: UserPublic | null | undefined,
  permission: Permission,
): boolean {
  if (!user) {
    return false
  }
  return ROLE_PERMISSIONS[user.role ?? "member"].includes(permission)
}
