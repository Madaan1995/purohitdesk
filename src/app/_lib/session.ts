import { command, withTenantTx } from '@/db';
import type { Identity } from './auth';
import type { Locale } from '@/domain/locale';
import type { Permission, Role } from '@/domain/permissions';

export interface SessionUser {
  id: string;
  display_name: string | null;
  preferred_locale: Locale;
}

export interface Membership {
  organization: { id: string; name: string; kind: 'SOLO' | 'COLLECTIVE'; timezone: string };
  role: Role;
  permissions: Permission[];
}

export interface Session {
  user: SessionUser;
  memberships: Membership[];
}

/**
 * First login creates the app user (ensure_current_user, with the token's display name); then the actor's ACTIVE
 * memberships with each role's permissions, read as app_runtime under RLS (no tenant selected: own memberships only).
 */
export async function loadSession(identity: Identity, cookieLocale: string | null): Promise<Session> {
  return withTenantTx({ actorId: identity.actorId }, async (tx) => {
    const user = await command<SessionUser>(
      tx`SELECT app.ensure_current_user(${cookieLocale}, ${identity.displayName}) AS result`,
    );
    const rows = await tx<{ id: string; name: string; kind: 'SOLO' | 'COLLECTIVE'; timezone: string; role: Role; permissions: Permission[] }[]>`
      SELECT o.id, o.name, o.kind, o.timezone, m.role,
             coalesce((SELECT array_agg(rp.permission ORDER BY rp.permission)
                       FROM app.role_permissions rp WHERE rp.role = m.role), '{}') AS permissions
      FROM app.org_members m
      JOIN app.organizations o ON o.id = m.org_id
      WHERE m.user_id = app.current_actor_id() AND m.status = 'ACTIVE' AND o.status = 'ACTIVE'
      ORDER BY o.created_at, o.id`;
    return {
      user,
      memberships: rows.map(({ id, name, kind, timezone, role, permissions }) => ({
        organization: { id, name, kind, timezone },
        role,
        permissions,
      })),
    };
  });
}
