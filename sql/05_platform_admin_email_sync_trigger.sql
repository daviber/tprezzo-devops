-- Migration: platform admin email -> profile role sync trigger
-- Date: 2026-03-05

-- =========================================================
-- Helper: sync one profile role from whitelist state
-- =========================================================

CREATE OR REPLACE FUNCTION public.sync_platform_admin_role_by_email(p_email TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_email TEXT;
  v_is_active BOOLEAN;
BEGIN
  v_email := LOWER(TRIM(COALESCE(p_email, '')));
  IF v_email = '' THEN
    RETURN;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.platform_admin_emails pae
    WHERE pae.email = v_email
      AND pae.is_active = TRUE
  )
  INTO v_is_active;

  IF v_is_active THEN
    UPDATE public.profiles
    SET role = 'platform_admin',
        updated_at = NOW()
    WHERE LOWER(TRIM(email)) = v_email
      AND role <> 'platform_admin';
  ELSE
    UPDATE public.profiles
    SET role = 'admin',
        updated_at = NOW()
    WHERE LOWER(TRIM(email)) = v_email
      AND role = 'platform_admin';
  END IF;
END;
$$;

-- =========================================================
-- Trigger: keep profiles.role aligned after email whitelist changes
-- =========================================================

CREATE OR REPLACE FUNCTION public.trg_sync_platform_admin_profiles()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM public.sync_platform_admin_role_by_email(NEW.email);
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    -- Re-sync old email as well in case email changed in whitelist row.
    IF OLD.email IS DISTINCT FROM NEW.email THEN
      PERFORM public.sync_platform_admin_role_by_email(OLD.email);
    END IF;
    PERFORM public.sync_platform_admin_role_by_email(NEW.email);
    RETURN NEW;
  END IF;

  -- DELETE
  PERFORM public.sync_platform_admin_role_by_email(OLD.email);
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS platform_admin_emails_sync_profiles ON public.platform_admin_emails;
CREATE TRIGGER platform_admin_emails_sync_profiles
AFTER INSERT OR UPDATE OR DELETE ON public.platform_admin_emails
FOR EACH ROW
EXECUTE FUNCTION public.trg_sync_platform_admin_profiles();

-- =========================================================
-- One-time alignment for existing data
-- =========================================================

UPDATE public.profiles p
SET role = 'platform_admin',
    updated_at = NOW()
FROM public.platform_admin_emails pae
WHERE pae.email = LOWER(TRIM(p.email))
  AND pae.is_active = TRUE
  AND p.role <> 'platform_admin';

UPDATE public.profiles p
SET role = 'admin',
    updated_at = NOW()
WHERE p.role = 'platform_admin'
  AND NOT EXISTS (
    SELECT 1
    FROM public.platform_admin_emails pae
    WHERE pae.email = LOWER(TRIM(p.email))
      AND pae.is_active = TRUE
  );
