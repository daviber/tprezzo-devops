-- Migration: User onboarding + role hardening
-- Date: 2026-03-03
--
-- Goals:
-- 1) The first user of a newly created organization is admin.
-- 2) Invited users are always created as employees in the inviter organization.
-- 3) Prevent profile privilege escalation through direct role/org updates.

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_org_id UUID;
  v_org_name TEXT;
  v_full_name TEXT;
  v_metadata_org_id UUID;
BEGIN
  v_org_name := COALESCE(NULLIF(TRIM(NEW.raw_user_meta_data ->> 'organization_name'), ''), 'Nuova organizzazione');
  v_full_name := NULLIF(TRIM(NEW.raw_user_meta_data ->> 'full_name'), '');

  IF NEW.invited_at IS NOT NULL THEN
    BEGIN
      v_metadata_org_id := NULLIF(TRIM(NEW.raw_user_meta_data ->> 'organization_id'), '')::UUID;
    EXCEPTION
      WHEN invalid_text_representation THEN
        v_metadata_org_id := NULL;
    END;

    IF v_metadata_org_id IS NULL THEN
      RAISE EXCEPTION 'Invited user missing organization_id metadata';
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM public.organizations
      WHERE id = v_metadata_org_id
    ) THEN
      RAISE EXCEPTION 'Organization not found for invited user';
    END IF;

    v_org_id := v_metadata_org_id;

    INSERT INTO public.profiles (
      id,
      email,
      full_name,
      role,
      organization_id
    ) VALUES (
      NEW.id,
      COALESCE(NEW.email, ''),
      COALESCE(v_full_name, NULLIF(SPLIT_PART(COALESCE(NEW.email, ''), '@', 1), '')),
      'employee',
      v_org_id
    )
    ON CONFLICT (id) DO UPDATE
    SET
      email = EXCLUDED.email,
      full_name = COALESCE(EXCLUDED.full_name, public.profiles.full_name),
      updated_at = NOW();
  ELSE
    INSERT INTO public.organizations (
      name,
      subscription_tier,
      subscription_status,
      max_users
    ) VALUES (
      v_org_name,
      'base',
      'active',
      1
    )
    RETURNING id INTO v_org_id;

    INSERT INTO public.profiles (
      id,
      email,
      full_name,
      role,
      organization_id
    ) VALUES (
      NEW.id,
      COALESCE(NEW.email, ''),
      COALESCE(v_full_name, NULLIF(SPLIT_PART(COALESCE(NEW.email, ''), '@', 1), '')),
      'admin',
      v_org_id
    )
    ON CONFLICT (id) DO UPDATE
    SET
      email = EXCLUDED.email,
      full_name = COALESCE(EXCLUDED.full_name, public.profiles.full_name),
      updated_at = NOW();
  END IF;

  RETURN NEW;
END;
$$;

DO $$
BEGIN
  IF to_regclass('auth.users') IS NOT NULL THEN
    EXECUTE 'DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users';
    EXECUTE 'CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.handle_new_user()';
  END IF;
END
$$;

-- Backfill: invited users should be employees in the invited organization.
WITH invited_users AS (
  SELECT
    u.id AS user_id,
    o.id AS organization_id
  FROM auth.users u
  JOIN public.organizations o
    ON o.id = (u.raw_user_meta_data ->> 'organization_id')::UUID
  WHERE u.invited_at IS NOT NULL
    AND COALESCE(NULLIF(LOWER(TRIM(u.raw_user_meta_data ->> 'role')), ''), 'employee') = 'employee'
    AND (u.raw_user_meta_data ->> 'organization_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
)
UPDATE public.profiles p
SET
  role = 'employee',
  organization_id = iu.organization_id,
  updated_at = NOW()
FROM invited_users iu
WHERE p.id = iu.user_id
  AND (
    p.role IS DISTINCT FROM 'employee'
    OR p.organization_id IS DISTINCT FROM iu.organization_id
  );

CREATE OR REPLACE FUNCTION public.protect_profile_role_fields()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Authenticated users cannot alter tenant boundaries or privilege level directly.
  IF auth.role() = 'authenticated' THEN
    IF NEW.organization_id IS DISTINCT FROM OLD.organization_id THEN
      RAISE EXCEPTION 'organization_id cannot be changed';
    END IF;

    IF NEW.role IS DISTINCT FROM OLD.role THEN
      RAISE EXCEPTION 'role cannot be changed directly';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS protect_profile_role_fields ON public.profiles;
CREATE TRIGGER protect_profile_role_fields
BEFORE UPDATE ON public.profiles
FOR EACH ROW
EXECUTE FUNCTION public.protect_profile_role_fields();

REVOKE UPDATE (role, organization_id) ON TABLE public.profiles FROM authenticated;
