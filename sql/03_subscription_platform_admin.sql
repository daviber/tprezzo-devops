-- Migration: Stripe subscriptions, platform admin console, employee supplier visibility
-- Date: 2026-03-03

-- =========================================================
-- Organizations: Stripe subscription metadata + constraint alignment
-- =========================================================

ALTER TABLE public.organizations
  ADD COLUMN IF NOT EXISTS stripe_customer_id TEXT,
  ADD COLUMN IF NOT EXISTS stripe_subscription_id TEXT,
  ADD COLUMN IF NOT EXISTS stripe_price_id TEXT,
  ADD COLUMN IF NOT EXISTS stripe_current_period_end TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS subscription_cancel_at_period_end BOOLEAN NOT NULL DEFAULT FALSE;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'organizations_stripe_customer_id_key'
  ) THEN
    CREATE UNIQUE INDEX organizations_stripe_customer_id_key
      ON public.organizations (stripe_customer_id)
      WHERE stripe_customer_id IS NOT NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'organizations_stripe_subscription_id_key'
  ) THEN
    CREATE UNIQUE INDEX organizations_stripe_subscription_id_key
      ON public.organizations (stripe_subscription_id)
      WHERE stripe_subscription_id IS NOT NULL;
  END IF;
END;
$$;

UPDATE public.organizations
SET subscription_tier = CASE
  WHEN subscription_tier IN ('medium', 'large') THEN 'premium'
  WHEN subscription_tier = 'premium' THEN 'premium'
  ELSE 'base'
END;

ALTER TABLE public.organizations
  DROP CONSTRAINT IF EXISTS organizations_subscription_tier_check;

ALTER TABLE public.organizations
  ADD CONSTRAINT organizations_subscription_tier_check
  CHECK (subscription_tier IN ('base', 'premium'));

ALTER TABLE public.organizations
  DROP CONSTRAINT IF EXISTS organizations_subscription_status_check;

ALTER TABLE public.organizations
  ADD CONSTRAINT organizations_subscription_status_check
  CHECK (
    subscription_status IN (
      'active',
      'inactive',
      'cancelled',
      'canceled',
      'trialing',
      'past_due',
      'unpaid',
      'incomplete',
      'incomplete_expired'
    )
  );

ALTER TABLE public.organizations
  ALTER COLUMN subscription_status SET DEFAULT 'inactive';

-- =========================================================
-- Roles: add platform_admin
-- =========================================================

ALTER TABLE public.profiles
  DROP CONSTRAINT IF EXISTS profiles_role_check;

ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_role_check
  CHECK (role IN ('admin', 'employee', 'platform_admin'));

-- =========================================================
-- Platform admin whitelist + plan configuration
-- =========================================================

CREATE TABLE IF NOT EXISTS public.platform_admin_emails (
  email TEXT PRIMARY KEY CHECK (email = LOWER(TRIM(email))),
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO public.platform_admin_emails (email)
VALUES ('davide@davide.com')
ON CONFLICT (email) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.platform_plan_settings (
  tier TEXT PRIMARY KEY CHECK (tier IN ('base', 'premium')),
  stripe_product_id TEXT,
  stripe_price_id TEXT,
  max_employees INTEGER CHECK (max_employees IS NULL OR max_employees >= 0),
  max_suppliers INTEGER CHECK (max_suppliers IS NULL OR max_suppliers >= 0),
  max_monthly_reports INTEGER CHECK (max_monthly_reports IS NULL OR max_monthly_reports >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO public.platform_plan_settings (
  tier,
  stripe_product_id,
  stripe_price_id,
  max_employees,
  max_suppliers,
  max_monthly_reports
)
VALUES
  ('base', NULL, NULL, 1, 30, 50),
  ('premium', NULL, NULL, NULL, NULL, NULL)
ON CONFLICT (tier) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.platform_plan_discounts (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  tier TEXT NOT NULL CHECK (tier IN ('base', 'premium')),
  coupon_code TEXT NOT NULL,
  stripe_promotion_code_id TEXT,
  auto_apply BOOLEAN NOT NULL DEFAULT FALSE,
  active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT platform_plan_discounts_tier_coupon_unique UNIQUE (tier, coupon_code)
);

CREATE INDEX IF NOT EXISTS idx_platform_plan_discounts_tier_active
  ON public.platform_plan_discounts (tier, active);

-- =========================================================
-- Employee supplier visibility
-- =========================================================

CREATE TABLE IF NOT EXISTS public.employee_supplier_visibility (
  employee_id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  can_view_all BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.employee_supplier_visibility_suppliers (
  employee_id UUID NOT NULL REFERENCES public.employee_supplier_visibility(employee_id) ON DELETE CASCADE,
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  supplier_id UUID NOT NULL REFERENCES public.suppliers(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (employee_id, supplier_id)
);

CREATE INDEX IF NOT EXISTS idx_employee_supplier_visibility_org
  ON public.employee_supplier_visibility (organization_id);

CREATE INDEX IF NOT EXISTS idx_employee_supplier_visibility_suppliers_org
  ON public.employee_supplier_visibility_suppliers (organization_id);

CREATE INDEX IF NOT EXISTS idx_employee_supplier_visibility_suppliers_supplier
  ON public.employee_supplier_visibility_suppliers (supplier_id);

CREATE OR REPLACE FUNCTION public.validate_employee_supplier_visibility()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_role TEXT;
  v_profile_org UUID;
BEGIN
  SELECT role, organization_id
  INTO v_role, v_profile_org
  FROM public.profiles
  WHERE id = NEW.employee_id;

  IF v_role IS NULL THEN
    RAISE EXCEPTION 'Employee profile not found';
  END IF;

  IF v_role <> 'employee' THEN
    RAISE EXCEPTION 'Visibility can be assigned only to employee profiles';
  END IF;

  IF NEW.organization_id IS DISTINCT FROM v_profile_org THEN
    RAISE EXCEPTION 'Employee organization mismatch';
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.validate_employee_supplier_visibility_supplier()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_visibility_org UUID;
  v_supplier_org UUID;
BEGIN
  SELECT organization_id
  INTO v_visibility_org
  FROM public.employee_supplier_visibility
  WHERE employee_id = NEW.employee_id;

  IF v_visibility_org IS NULL THEN
    RAISE EXCEPTION 'Employee visibility row not found';
  END IF;

  IF NEW.organization_id IS DISTINCT FROM v_visibility_org THEN
    RAISE EXCEPTION 'Visibility organization mismatch';
  END IF;

  SELECT organization_id
  INTO v_supplier_org
  FROM public.suppliers
  WHERE id = NEW.supplier_id;

  IF v_supplier_org IS NULL THEN
    RAISE EXCEPTION 'Supplier not found';
  END IF;

  IF NEW.organization_id IS DISTINCT FROM v_supplier_org THEN
    RAISE EXCEPTION 'Supplier organization mismatch';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS validate_employee_supplier_visibility_trg ON public.employee_supplier_visibility;
CREATE TRIGGER validate_employee_supplier_visibility_trg
BEFORE INSERT OR UPDATE ON public.employee_supplier_visibility
FOR EACH ROW
EXECUTE FUNCTION public.validate_employee_supplier_visibility();

DROP TRIGGER IF EXISTS validate_employee_supplier_visibility_supplier_trg ON public.employee_supplier_visibility_suppliers;
CREATE TRIGGER validate_employee_supplier_visibility_supplier_trg
BEFORE INSERT OR UPDATE ON public.employee_supplier_visibility_suppliers
FOR EACH ROW
EXECUTE FUNCTION public.validate_employee_supplier_visibility_supplier();

INSERT INTO public.employee_supplier_visibility (employee_id, organization_id, can_view_all)
SELECT p.id, p.organization_id, TRUE
FROM public.profiles p
WHERE p.role = 'employee'
ON CONFLICT (employee_id) DO NOTHING;

-- =========================================================
-- Updated-at triggers for new tables
-- =========================================================

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS set_updated_at_platform_admin_emails ON public.platform_admin_emails;
CREATE TRIGGER set_updated_at_platform_admin_emails
BEFORE UPDATE ON public.platform_admin_emails
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS set_updated_at_platform_plan_settings ON public.platform_plan_settings;
CREATE TRIGGER set_updated_at_platform_plan_settings
BEFORE UPDATE ON public.platform_plan_settings
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS set_updated_at_platform_plan_discounts ON public.platform_plan_discounts;
CREATE TRIGGER set_updated_at_platform_plan_discounts
BEFORE UPDATE ON public.platform_plan_discounts
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS set_updated_at_employee_supplier_visibility ON public.employee_supplier_visibility;
CREATE TRIGGER set_updated_at_employee_supplier_visibility
BEFORE UPDATE ON public.employee_supplier_visibility
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

-- =========================================================
-- Helpers and onboarding trigger updates
-- =========================================================

CREATE OR REPLACE FUNCTION public.current_user_role()
RETURNS TEXT
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT role
  FROM public.profiles
  WHERE id = auth.uid()
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.is_current_user_platform_admin()
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE((
    SELECT role = 'platform_admin'
    FROM public.profiles
    WHERE id = auth.uid()
    LIMIT 1
  ), FALSE);
$$;

CREATE OR REPLACE FUNCTION public.can_current_user_access_supplier(p_supplier_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile RECORD;
  v_can_view_all BOOLEAN;
BEGIN
  SELECT id, role, organization_id
  INTO v_profile
  FROM public.profiles
  WHERE id = auth.uid()
  LIMIT 1;

  IF v_profile.id IS NULL THEN
    RETURN FALSE;
  END IF;

  IF p_supplier_id IS NULL THEN
    RETURN FALSE;
  END IF;

  IF v_profile.role = 'admin' OR v_profile.role = 'platform_admin' THEN
    RETURN EXISTS (
      SELECT 1
      FROM public.suppliers s
      WHERE s.id = p_supplier_id
        AND s.organization_id = v_profile.organization_id
    );
  END IF;

  IF v_profile.role <> 'employee' THEN
    RETURN FALSE;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.suppliers s
    WHERE s.id = p_supplier_id
      AND s.organization_id = v_profile.organization_id
  ) THEN
    RETURN FALSE;
  END IF;

  SELECT v.can_view_all
  INTO v_can_view_all
  FROM public.employee_supplier_visibility v
  WHERE v.employee_id = v_profile.id
  LIMIT 1;

  IF v_can_view_all IS NULL THEN
    RETURN TRUE;
  END IF;

  IF v_can_view_all THEN
    RETURN TRUE;
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.employee_supplier_visibility_suppliers es
    WHERE es.employee_id = v_profile.id
      AND es.organization_id = v_profile.organization_id
      AND es.supplier_id = p_supplier_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.can_current_user_manage_agreement(p_agreement_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role TEXT;
  v_org_id UUID;
  v_supplier_id UUID;
BEGIN
  SELECT role, organization_id
  INTO v_role, v_org_id
  FROM public.profiles
  WHERE id = auth.uid()
  LIMIT 1;

  IF v_role IS NULL THEN
    RETURN FALSE;
  END IF;

  SELECT supplier_id
  INTO v_supplier_id
  FROM public.agreements a
  WHERE a.id = p_agreement_id
    AND a.organization_id = v_org_id
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN FALSE;
  END IF;

  IF v_role = 'admin' OR v_role = 'platform_admin' THEN
    RETURN TRUE;
  END IF;

  IF v_role <> 'employee' THEN
    RETURN FALSE;
  END IF;

  RETURN public.can_current_user_access_supplier(v_supplier_id);
END;
$$;

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
  v_is_platform_admin BOOLEAN := FALSE;
  v_role TEXT := 'admin';
BEGIN
  v_org_name := COALESCE(NULLIF(TRIM(NEW.raw_user_meta_data ->> 'organization_name'), ''), 'Nuova organizzazione');
  v_full_name := NULLIF(TRIM(NEW.raw_user_meta_data ->> 'full_name'), '');

  IF NEW.email IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.platform_admin_emails pae
      WHERE pae.email = LOWER(TRIM(NEW.email))
        AND pae.is_active = TRUE
    )
    INTO v_is_platform_admin;

    IF v_is_platform_admin THEN
      v_role := 'platform_admin';
    END IF;
  END IF;

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

    INSERT INTO public.employee_supplier_visibility (employee_id, organization_id, can_view_all)
    VALUES (NEW.id, v_org_id, TRUE)
    ON CONFLICT (employee_id) DO NOTHING;
  ELSE
    INSERT INTO public.organizations (
      name,
      subscription_tier,
      subscription_status,
      max_users
    ) VALUES (
      v_org_name,
      'base',
      'inactive',
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
      v_role,
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

UPDATE public.profiles p
SET role = 'platform_admin',
    updated_at = NOW()
FROM public.platform_admin_emails pae
WHERE pae.email = LOWER(TRIM(p.email))
  AND pae.is_active = TRUE
  AND p.role <> 'platform_admin';

-- =========================================================
-- Harden RPC used for full agreement update
-- =========================================================

CREATE OR REPLACE FUNCTION public.update_agreement_with_items(
  p_agreement_id UUID,
  p_organization_id UUID,
  p_user_id UUID,
  p_name TEXT,
  p_supplier_id UUID,
  p_validity_start DATE,
  p_validity_end DATE,
  p_status TEXT DEFAULT NULL,
  p_items JSONB DEFAULT '[]'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_supplier_name TEXT := '';
  v_item JSONB;
  v_result JSONB;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF p_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Invalid user context';
  END IF;

  IF p_organization_id IS DISTINCT FROM public.current_organization_id() THEN
    RAISE EXCEPTION 'Invalid organization context';
  END IF;

  IF NOT public.can_current_user_manage_agreement(p_agreement_id) THEN
    RAISE EXCEPTION 'Access denied for agreement management';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.agreements
    WHERE id = p_agreement_id
      AND organization_id = p_organization_id
  ) THEN
    RAISE EXCEPTION 'Agreement not found or access denied';
  END IF;

  IF p_supplier_id IS NOT NULL THEN
    SELECT name INTO v_supplier_name
    FROM public.suppliers
    WHERE id = p_supplier_id
      AND organization_id = p_organization_id;

    IF v_supplier_name IS NULL THEN
      RAISE EXCEPTION 'Supplier not found';
    END IF;

    IF NOT public.can_current_user_access_supplier(p_supplier_id) THEN
      RAISE EXCEPTION 'Supplier access denied';
    END IF;
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb))
  LOOP
    IF v_item->>'item_name' IS NULL OR TRIM(v_item->>'item_name') = '' THEN
      RAISE EXCEPTION 'All items must have a valid name';
    END IF;
    IF v_item->>'unit_price' IS NULL OR NOT (v_item->>'unit_price' ~ '^[0-9]+(\.[0-9]+)?$') THEN
      RAISE EXCEPTION 'All items must have a valid price';
    END IF;
  END LOOP;

  UPDATE public.agreements
  SET
    name = p_name,
    supplier_id = p_supplier_id,
    validity_start = p_validity_start,
    validity_end = p_validity_end,
    status = COALESCE(p_status, status),
    updated_at = NOW()
  WHERE id = p_agreement_id
    AND organization_id = p_organization_id;

  DELETE FROM public.agreement_items
  WHERE agreement_id = p_agreement_id;

  INSERT INTO public.agreement_items (
    agreement_id,
    organization_id,
    supplier_name,
    item_name,
    item_name_normalized,
    unit_price,
    unit_of_measure,
    category,
    notes
  )
  SELECT
    p_agreement_id,
    p_organization_id,
    NULLIF(v_supplier_name, ''),
    item->>'item_name',
    normalize_item_name(item->>'item_name'),
    (item->>'unit_price')::DECIMAL(10,2),
    item->>'unit_of_measure',
    item->>'category',
    item->>'notes'
  FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) AS item;

  INSERT INTO public.audit_logs (
    organization_id,
    user_id,
    action,
    entity_type,
    entity_id,
    details
  ) VALUES (
    p_organization_id,
    p_user_id,
    'update_agreement',
    'agreement',
    p_agreement_id,
    jsonb_build_object('name', p_name)
  );

  v_result := jsonb_build_object(
    'success', true,
    'agreement_id', p_agreement_id,
    'items_count', jsonb_array_length(COALESCE(p_items, '[]'::jsonb))
  );

  RETURN v_result;
END;
$$;

-- =========================================================
-- RLS on new tables
-- =========================================================

ALTER TABLE public.platform_admin_emails ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.platform_plan_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.platform_plan_discounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.employee_supplier_visibility ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.employee_supplier_visibility_suppliers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS platform_admin_emails_select ON public.platform_admin_emails;
CREATE POLICY platform_admin_emails_select
ON public.platform_admin_emails
FOR SELECT
TO authenticated
USING (public.is_current_user_platform_admin());

DROP POLICY IF EXISTS platform_admin_emails_write ON public.platform_admin_emails;
CREATE POLICY platform_admin_emails_write
ON public.platform_admin_emails
FOR ALL
TO authenticated
USING (public.is_current_user_platform_admin())
WITH CHECK (public.is_current_user_platform_admin());

DROP POLICY IF EXISTS platform_admin_emails_service_role_all ON public.platform_admin_emails;
CREATE POLICY platform_admin_emails_service_role_all
ON public.platform_admin_emails
FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

DROP POLICY IF EXISTS platform_plan_settings_select ON public.platform_plan_settings;
CREATE POLICY platform_plan_settings_select
ON public.platform_plan_settings
FOR SELECT
TO authenticated
USING (public.is_current_user_platform_admin());

DROP POLICY IF EXISTS platform_plan_settings_write ON public.platform_plan_settings;
CREATE POLICY platform_plan_settings_write
ON public.platform_plan_settings
FOR ALL
TO authenticated
USING (public.is_current_user_platform_admin())
WITH CHECK (public.is_current_user_platform_admin());

DROP POLICY IF EXISTS platform_plan_settings_service_role_all ON public.platform_plan_settings;
CREATE POLICY platform_plan_settings_service_role_all
ON public.platform_plan_settings
FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

DROP POLICY IF EXISTS platform_plan_discounts_select ON public.platform_plan_discounts;
CREATE POLICY platform_plan_discounts_select
ON public.platform_plan_discounts
FOR SELECT
TO authenticated
USING (public.is_current_user_platform_admin());

DROP POLICY IF EXISTS platform_plan_discounts_write ON public.platform_plan_discounts;
CREATE POLICY platform_plan_discounts_write
ON public.platform_plan_discounts
FOR ALL
TO authenticated
USING (public.is_current_user_platform_admin())
WITH CHECK (public.is_current_user_platform_admin());

DROP POLICY IF EXISTS platform_plan_discounts_service_role_all ON public.platform_plan_discounts;
CREATE POLICY platform_plan_discounts_service_role_all
ON public.platform_plan_discounts
FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

DROP POLICY IF EXISTS employee_supplier_visibility_select ON public.employee_supplier_visibility;
CREATE POLICY employee_supplier_visibility_select
ON public.employee_supplier_visibility
FOR SELECT
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND (
    public.is_current_user_admin()
    OR employee_id = auth.uid()
  )
);

DROP POLICY IF EXISTS employee_supplier_visibility_write_admin ON public.employee_supplier_visibility;
CREATE POLICY employee_supplier_visibility_write_admin
ON public.employee_supplier_visibility
FOR ALL
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND public.is_current_user_admin()
)
WITH CHECK (
  organization_id = public.current_organization_id()
  AND public.is_current_user_admin()
);

DROP POLICY IF EXISTS employee_supplier_visibility_service_role_all ON public.employee_supplier_visibility;
CREATE POLICY employee_supplier_visibility_service_role_all
ON public.employee_supplier_visibility
FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

DROP POLICY IF EXISTS employee_supplier_visibility_suppliers_select ON public.employee_supplier_visibility_suppliers;
CREATE POLICY employee_supplier_visibility_suppliers_select
ON public.employee_supplier_visibility_suppliers
FOR SELECT
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND (
    public.is_current_user_admin()
    OR employee_id = auth.uid()
  )
);

DROP POLICY IF EXISTS employee_supplier_visibility_suppliers_write_admin ON public.employee_supplier_visibility_suppliers;
CREATE POLICY employee_supplier_visibility_suppliers_write_admin
ON public.employee_supplier_visibility_suppliers
FOR ALL
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND public.is_current_user_admin()
)
WITH CHECK (
  organization_id = public.current_organization_id()
  AND public.is_current_user_admin()
);

DROP POLICY IF EXISTS employee_supplier_visibility_suppliers_service_role_all ON public.employee_supplier_visibility_suppliers;
CREATE POLICY employee_supplier_visibility_suppliers_service_role_all
ON public.employee_supplier_visibility_suppliers
FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

-- =========================================================
-- RLS refinements with employee supplier visibility
-- =========================================================

DROP POLICY IF EXISTS suppliers_select_same_org ON public.suppliers;
CREATE POLICY suppliers_select_same_org
ON public.suppliers
FOR SELECT
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND public.can_current_user_access_supplier(id)
);

DROP POLICY IF EXISTS agreements_select_same_org ON public.agreements;
CREATE POLICY agreements_select_same_org
ON public.agreements
FOR SELECT
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND (
    supplier_id IS NULL
    OR public.can_current_user_access_supplier(supplier_id)
  )
);

DROP POLICY IF EXISTS agreements_update_admin ON public.agreements;
DROP POLICY IF EXISTS agreements_update_managed ON public.agreements;
CREATE POLICY agreements_update_managed
ON public.agreements
FOR UPDATE
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND (
    public.is_current_user_admin()
    OR (
      public.current_user_role() = 'employee'
      AND (supplier_id IS NULL OR public.can_current_user_access_supplier(supplier_id))
    )
  )
)
WITH CHECK (
  organization_id = public.current_organization_id()
  AND (
    public.is_current_user_admin()
    OR (
      public.current_user_role() = 'employee'
      AND (supplier_id IS NULL OR public.can_current_user_access_supplier(supplier_id))
    )
  )
);

DROP POLICY IF EXISTS agreements_delete_admin ON public.agreements;
DROP POLICY IF EXISTS agreements_delete_managed ON public.agreements;
CREATE POLICY agreements_delete_managed
ON public.agreements
FOR DELETE
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND (
    public.is_current_user_admin()
    OR (
      public.current_user_role() = 'employee'
      AND (supplier_id IS NULL OR public.can_current_user_access_supplier(supplier_id))
    )
  )
);

DROP POLICY IF EXISTS agreement_items_select_same_org ON public.agreement_items;
CREATE POLICY agreement_items_select_same_org
ON public.agreement_items
FOR SELECT
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND public.can_current_user_manage_agreement(agreement_id)
);

DROP POLICY IF EXISTS agreement_items_update_admin ON public.agreement_items;
DROP POLICY IF EXISTS agreement_items_update_managed ON public.agreement_items;
CREATE POLICY agreement_items_update_managed
ON public.agreement_items
FOR UPDATE
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND (
    public.is_current_user_admin()
    OR (
      public.current_user_role() = 'employee'
      AND public.can_current_user_manage_agreement(agreement_id)
    )
  )
)
WITH CHECK (
  organization_id = public.current_organization_id()
  AND (
    public.is_current_user_admin()
    OR (
      public.current_user_role() = 'employee'
      AND public.can_current_user_manage_agreement(agreement_id)
    )
  )
);

DROP POLICY IF EXISTS agreement_items_delete_admin ON public.agreement_items;
DROP POLICY IF EXISTS agreement_items_delete_managed ON public.agreement_items;
CREATE POLICY agreement_items_delete_managed
ON public.agreement_items
FOR DELETE
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND (
    public.is_current_user_admin()
    OR (
      public.current_user_role() = 'employee'
      AND public.can_current_user_manage_agreement(agreement_id)
    )
  )
);

DROP POLICY IF EXISTS invoices_select_same_org ON public.invoices;
CREATE POLICY invoices_select_same_org
ON public.invoices
FOR SELECT
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND public.can_current_user_access_supplier(supplier_id)
);

DROP POLICY IF EXISTS invoices_insert_same_org ON public.invoices;
CREATE POLICY invoices_insert_same_org
ON public.invoices
FOR INSERT
TO authenticated
WITH CHECK (
  organization_id = public.current_organization_id()
  AND public.can_current_user_access_supplier(supplier_id)
);

DROP POLICY IF EXISTS invoices_update_same_org ON public.invoices;
CREATE POLICY invoices_update_same_org
ON public.invoices
FOR UPDATE
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND public.can_current_user_access_supplier(supplier_id)
)
WITH CHECK (
  organization_id = public.current_organization_id()
  AND public.can_current_user_access_supplier(supplier_id)
);

DROP POLICY IF EXISTS invoices_delete_same_org ON public.invoices;
CREATE POLICY invoices_delete_same_org
ON public.invoices
FOR DELETE
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND public.can_current_user_access_supplier(supplier_id)
);

DROP POLICY IF EXISTS invoice_items_select_same_org ON public.invoice_items;
CREATE POLICY invoice_items_select_same_org
ON public.invoice_items
FOR SELECT
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND EXISTS (
    SELECT 1
    FROM public.invoices i
    WHERE i.id = invoice_id
      AND i.organization_id = public.current_organization_id()
      AND public.can_current_user_access_supplier(i.supplier_id)
  )
);

DROP POLICY IF EXISTS reports_select_same_org ON public.reports;
CREATE POLICY reports_select_same_org
ON public.reports
FOR SELECT
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND public.can_current_user_access_supplier(supplier_id)
);

DROP POLICY IF EXISTS reports_insert_same_org ON public.reports;
CREATE POLICY reports_insert_same_org
ON public.reports
FOR INSERT
TO authenticated
WITH CHECK (
  organization_id = public.current_organization_id()
  AND public.can_current_user_access_supplier(supplier_id)
);

DROP POLICY IF EXISTS reports_update_same_org ON public.reports;
CREATE POLICY reports_update_same_org
ON public.reports
FOR UPDATE
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND public.can_current_user_access_supplier(supplier_id)
)
WITH CHECK (
  organization_id = public.current_organization_id()
  AND public.can_current_user_access_supplier(supplier_id)
);

DROP POLICY IF EXISTS reports_delete_same_org ON public.reports;
CREATE POLICY reports_delete_same_org
ON public.reports
FOR DELETE
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND public.can_current_user_access_supplier(supplier_id)
);

DROP POLICY IF EXISTS report_items_select_same_org ON public.report_items;
CREATE POLICY report_items_select_same_org
ON public.report_items
FOR SELECT
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND EXISTS (
    SELECT 1
    FROM public.reports r
    WHERE r.id = report_id
      AND r.organization_id = public.current_organization_id()
      AND public.can_current_user_access_supplier(r.supplier_id)
  )
);

-- =========================================================
-- Permissions for new tables
-- =========================================================

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.platform_admin_emails TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.platform_plan_settings TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.platform_plan_discounts TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.employee_supplier_visibility TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.employee_supplier_visibility_suppliers TO authenticated, service_role;
