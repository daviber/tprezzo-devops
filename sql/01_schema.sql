-- =========================================================
-- TPREZZO local schema bootstrap
-- Idempotent script executed on first DB init.
-- =========================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS unaccent;
CREATE EXTENSION IF NOT EXISTS pg_cron;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'postgres') THEN
    CREATE ROLE postgres NOLOGIN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN NOINHERIT;
  END IF;
  ALTER ROLE anon NOLOGIN NOINHERIT;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN NOINHERIT;
  END IF;
  ALTER ROLE authenticated NOLOGIN NOINHERIT;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;
  END IF;
  ALTER ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;
END
$$;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS storage;

CREATE TABLE IF NOT EXISTS auth.users (
  instance_id uuid NULL,
  id uuid NOT NULL UNIQUE,
  aud varchar(255) NULL,
  "role" varchar(255) NULL,
  email varchar(255) NULL UNIQUE,
  encrypted_password varchar(255) NULL,
  confirmed_at timestamptz NULL,
  invited_at timestamptz NULL,
  confirmation_token varchar(255) NULL,
  confirmation_sent_at timestamptz NULL,
  recovery_token varchar(255) NULL,
  recovery_sent_at timestamptz NULL,
  email_change_token varchar(255) NULL,
  email_change varchar(255) NULL,
  email_change_sent_at timestamptz NULL,
  last_sign_in_at timestamptz NULL,
  raw_app_meta_data jsonb NULL,
  raw_user_meta_data jsonb NULL,
  is_super_admin bool NULL,
  created_at timestamptz NULL,
  updated_at timestamptz NULL,
  CONSTRAINT users_pkey PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS users_instance_id_email_idx ON auth.users USING btree (instance_id, email);
CREATE INDEX IF NOT EXISTS users_instance_id_idx ON auth.users USING btree (instance_id);

CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

CREATE OR REPLACE FUNCTION auth.role()
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.role', true), '')::text;
$$;

-- =========================================================
-- Core tables
-- =========================================================

CREATE TABLE IF NOT EXISTS public.organizations (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name TEXT NOT NULL,
  subscription_tier TEXT NOT NULL DEFAULT 'base' CHECK (subscription_tier IN ('base', 'premium')),
  subscription_status TEXT NOT NULL DEFAULT 'active' CHECK (subscription_status IN ('active', 'inactive', 'cancelled')),
  max_users INTEGER NOT NULL DEFAULT 1,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  full_name TEXT,
  role TEXT NOT NULL DEFAULT 'employee' CHECK (role IN ('admin', 'employee')),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.suppliers (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  contact_email TEXT,
  contact_phone TEXT,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.agreements (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  supplier_id UUID REFERENCES public.suppliers(id) ON DELETE SET NULL,
  name TEXT NOT NULL,
  file_url TEXT,
  file_type TEXT,
  validity_start DATE DEFAULT CURRENT_DATE,
  validity_end DATE,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'expired', 'archived')),
  delivery_included BOOLEAN,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.agreement_items (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agreement_id UUID NOT NULL REFERENCES public.agreements(id) ON DELETE CASCADE,
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  supplier_name TEXT,
  item_code TEXT,
  item_name TEXT NOT NULL,
  item_name_normalized TEXT NOT NULL,
  unit_price DECIMAL(10, 2) NOT NULL,
  category TEXT,
  unit_of_measure TEXT,
  container_type TEXT,
  container_confidence DECIMAL(4, 3),
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.invoices (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  supplier_id UUID NOT NULL REFERENCES public.suppliers(id) ON DELETE CASCADE,
  agreement_id UUID REFERENCES public.agreements(id) ON DELETE SET NULL,
  invoice_number TEXT,
  invoice_date DATE,
  file_url TEXT,
  file_type TEXT NOT NULL,
  processing_status TEXT NOT NULL DEFAULT 'pending' CHECK (processing_status IN ('pending', 'processing', 'completed', 'failed')),
  processing_error TEXT,
  delivery_included BOOLEAN,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.invoice_items (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  invoice_id UUID NOT NULL REFERENCES public.invoices(id) ON DELETE CASCADE,
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  supplier_name TEXT,
  item_code TEXT,
  item_name TEXT NOT NULL,
  item_name_normalized TEXT NOT NULL,
  unit_of_measure TEXT,
  container_type TEXT,
  container_confidence DECIMAL(4, 3),
  quantity DECIMAL(10, 3) NOT NULL,
  unit_price_gross DECIMAL(10, 2) NOT NULL,
  discount_percentage DECIMAL(5, 2) DEFAULT 0,
  discount_amount DECIMAL(10, 2) DEFAULT 0,
  unit_price_net DECIMAL(10, 2) NOT NULL,
  total_amount DECIMAL(10, 2) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.reports (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  invoice_id UUID NOT NULL REFERENCES public.invoices(id) ON DELETE CASCADE,
  agreement_id UUID NOT NULL REFERENCES public.agreements(id) ON DELETE CASCADE,
  supplier_id UUID NOT NULL REFERENCES public.suppliers(id) ON DELETE CASCADE,
  total_items_checked INTEGER NOT NULL,
  items_with_overcharge INTEGER NOT NULL,
  total_overcharge_amount DECIMAL(10, 2) NOT NULL,
  report_date DATE NOT NULL DEFAULT CURRENT_DATE,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  admin_notified BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.report_items (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  report_id UUID NOT NULL REFERENCES public.reports(id) ON DELETE CASCADE,
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  invoice_item_id UUID NOT NULL REFERENCES public.invoice_items(id) ON DELETE CASCADE,
  agreement_item_id UUID REFERENCES public.agreement_items(id) ON DELETE SET NULL,
  item_name_invoice TEXT NOT NULL,
  item_name_agreement TEXT,
  match_method TEXT,
  unit_of_measure_invoice TEXT,
  unit_of_measure_agreement TEXT,
  uom_mismatch BOOLEAN NOT NULL DEFAULT FALSE,
  container_type_invoice TEXT,
  container_type_agreement TEXT,
  container_mismatch BOOLEAN NOT NULL DEFAULT FALSE,
  match_confidence DECIMAL(5, 4),
  suggested_agreement_item_id UUID REFERENCES public.agreement_items(id) ON DELETE SET NULL,
  suggested_item_name_agreement TEXT,
  suggested_match_method TEXT,
  suggested_unit_of_measure_agreement TEXT,
  suggested_uom_mismatch BOOLEAN NOT NULL DEFAULT FALSE,
  suggested_container_type_agreement TEXT,
  suggested_container_mismatch BOOLEAN NOT NULL DEFAULT FALSE,
  suggested_match_confidence DECIMAL(5, 4),
  quantity DECIMAL(10, 3) NOT NULL,
  price_invoice DECIMAL(10, 2) NOT NULL,
  price_agreement DECIMAL(10, 2),
  price_difference DECIMAL(10, 2),
  total_overcharge DECIMAL(10, 2),
  category TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.confirmed_supplier_matches (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  supplier_id UUID NOT NULL REFERENCES public.suppliers(id) ON DELETE CASCADE,
  agreement_id UUID NOT NULL REFERENCES public.agreements(id) ON DELETE CASCADE,
  agreement_item_id UUID NOT NULL REFERENCES public.agreement_items(id) ON DELETE CASCADE,
  source_report_item_id UUID REFERENCES public.report_items(id) ON DELETE SET NULL,
  invoice_match_key TEXT NOT NULL,
  invoice_canonical_name TEXT NOT NULL,
  invoice_item_code_normalized TEXT,
  invoice_unit_of_measure_normalized TEXT,
  confirmation_count INTEGER NOT NULL DEFAULT 1,
  last_confirmed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT confirmed_supplier_matches_unique_key UNIQUE (organization_id, supplier_id, agreement_id, invoice_match_key)
);

CREATE TABLE IF NOT EXISTS public.audit_logs (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  organization_id UUID REFERENCES public.organizations(id) ON DELETE CASCADE,
  user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  action TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id UUID,
  details JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.user_activity_events (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  event_type TEXT NOT NULL CHECK (event_type IN ('page_view', 'login_success', 'workflow_event')),
  path TEXT,
  workflow TEXT,
  step TEXT,
  workflow_status TEXT,
  duration_ms INTEGER,
  error_code TEXT,
  subject_hash TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT user_activity_events_path_check CHECK (
    (
      event_type = 'page_view'
      AND path IS NOT NULL
      AND path <> ''
      AND workflow IS NULL
      AND step IS NULL
      AND workflow_status IS NULL
    )
    OR
    (
      event_type = 'login_success'
      AND path IS NULL
      AND workflow IS NULL
      AND step IS NULL
      AND workflow_status IS NULL
    )
    OR
    (
      event_type = 'workflow_event'
      AND path IS NULL
      AND workflow IS NOT NULL
      AND workflow <> ''
      AND step IS NOT NULL
      AND step <> ''
      AND workflow_status IN ('started', 'queued', 'completed', 'failed', 'skipped')
    )
  ),
  CONSTRAINT user_activity_events_duration_ms_check CHECK (
    duration_ms IS NULL OR duration_ms >= 0
  )
);

CREATE TABLE IF NOT EXISTS public.extraction_jobs (
  id TEXT PRIMARY KEY,
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  status TEXT NOT NULL CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
  progress TEXT,
  result JSONB,
  error TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.api_rate_limits (
  scope TEXT NOT NULL,
  identifier TEXT NOT NULL,
  count INTEGER NOT NULL DEFAULT 0,
  window_start TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  window_end TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (scope, identifier)
);

CREATE TABLE IF NOT EXISTS public.organization_audit_log (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  user_email TEXT NOT NULL,
  user_name TEXT,
  action TEXT NOT NULL,
  field_name TEXT NOT NULL,
  old_value TEXT,
  new_value TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 20260225_add_delivery_included.sql (backported into bootstrap schema)
ALTER TABLE public.agreements
  ADD COLUMN IF NOT EXISTS delivery_included BOOLEAN DEFAULT NULL;

ALTER TABLE public.invoices
  ADD COLUMN IF NOT EXISTS delivery_included BOOLEAN DEFAULT NULL;

-- 20260419_invoice_uom_alignment.sql (backported into bootstrap schema)
ALTER TABLE public.invoice_items
  ADD COLUMN IF NOT EXISTS unit_of_measure TEXT;

ALTER TABLE public.report_items
  ADD COLUMN IF NOT EXISTS unit_of_measure_invoice TEXT;

ALTER TABLE public.report_items
  ADD COLUMN IF NOT EXISTS unit_of_measure_agreement TEXT;

ALTER TABLE public.report_items
  ADD COLUMN IF NOT EXISTS uom_mismatch BOOLEAN NOT NULL DEFAULT FALSE;

-- =========================================================
-- Indexes
-- =========================================================

CREATE INDEX IF NOT EXISTS idx_profiles_org ON public.profiles(organization_id);
CREATE INDEX IF NOT EXISTS idx_suppliers_org ON public.suppliers(organization_id);
CREATE INDEX IF NOT EXISTS idx_agreements_org ON public.agreements(organization_id);
CREATE INDEX IF NOT EXISTS idx_agreements_supplier ON public.agreements(supplier_id);
CREATE INDEX IF NOT EXISTS idx_agreement_items_agreement ON public.agreement_items(agreement_id);
CREATE INDEX IF NOT EXISTS idx_agreement_items_org ON public.agreement_items(organization_id);
CREATE INDEX IF NOT EXISTS idx_agreement_items_supplier_name ON public.agreement_items(supplier_name);
CREATE INDEX IF NOT EXISTS idx_agreement_items_normalized ON public.agreement_items(item_name_normalized);
CREATE INDEX IF NOT EXISTS idx_agreement_items_code ON public.agreement_items(item_code) WHERE item_code IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_invoices_org ON public.invoices(organization_id);
CREATE INDEX IF NOT EXISTS idx_invoice_items_invoice ON public.invoice_items(invoice_id);
CREATE INDEX IF NOT EXISTS idx_invoice_items_supplier_name ON public.invoice_items(supplier_name);
CREATE INDEX IF NOT EXISTS idx_invoice_items_normalized ON public.invoice_items(item_name_normalized);
CREATE INDEX IF NOT EXISTS idx_invoice_items_code ON public.invoice_items(item_code) WHERE item_code IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_reports_org ON public.reports(organization_id);
CREATE INDEX IF NOT EXISTS idx_reports_date ON public.reports(report_date);
CREATE INDEX IF NOT EXISTS idx_report_items_report ON public.report_items(report_id);
CREATE INDEX IF NOT EXISTS idx_report_items_category ON public.report_items(category);
CREATE INDEX IF NOT EXISTS idx_report_items_suggested_agreement_item ON public.report_items(suggested_agreement_item_id);
CREATE INDEX IF NOT EXISTS idx_confirmed_supplier_matches_org_supplier ON public.confirmed_supplier_matches(organization_id, supplier_id);
CREATE INDEX IF NOT EXISTS idx_confirmed_supplier_matches_org_supplier_agreement ON public.confirmed_supplier_matches(organization_id, supplier_id, agreement_id);
CREATE INDEX IF NOT EXISTS idx_confirmed_supplier_matches_agreement_item ON public.confirmed_supplier_matches(agreement_item_id);
CREATE INDEX IF NOT EXISTS idx_user_activity_events_org_created_at ON public.user_activity_events(organization_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_user_activity_events_user_created_at ON public.user_activity_events(user_id, created_at DESC) WHERE user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_user_activity_events_type_created_at ON public.user_activity_events(event_type, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_user_activity_events_path_created_at ON public.user_activity_events(path, created_at DESC) WHERE path IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_user_activity_events_workflow_created_at ON public.user_activity_events(workflow, created_at DESC) WHERE workflow IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_user_activity_events_subject_hash_created_at ON public.user_activity_events(subject_hash, created_at ASC) WHERE subject_hash IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_extraction_jobs_org_user ON public.extraction_jobs(organization_id, user_id);
CREATE INDEX IF NOT EXISTS idx_extraction_jobs_status ON public.extraction_jobs(status);
CREATE INDEX IF NOT EXISTS idx_api_rate_limits_window_end ON public.api_rate_limits(window_end);
CREATE INDEX IF NOT EXISTS idx_org_audit_log_org_id ON public.organization_audit_log(organization_id);
CREATE INDEX IF NOT EXISTS idx_org_audit_log_created_at ON public.organization_audit_log(created_at DESC);

-- =========================================================
-- Generic updated_at trigger
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

DROP TRIGGER IF EXISTS set_updated_at_organizations ON public.organizations;
CREATE TRIGGER set_updated_at_organizations
BEFORE UPDATE ON public.organizations
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS set_updated_at_profiles ON public.profiles;
CREATE TRIGGER set_updated_at_profiles
BEFORE UPDATE ON public.profiles
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS set_updated_at_suppliers ON public.suppliers;
CREATE TRIGGER set_updated_at_suppliers
BEFORE UPDATE ON public.suppliers
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS set_updated_at_agreements ON public.agreements;
CREATE TRIGGER set_updated_at_agreements
BEFORE UPDATE ON public.agreements
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS set_updated_at_agreement_items ON public.agreement_items;
CREATE TRIGGER set_updated_at_agreement_items
BEFORE UPDATE ON public.agreement_items
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS set_updated_at_invoices ON public.invoices;
CREATE TRIGGER set_updated_at_invoices
BEFORE UPDATE ON public.invoices
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS set_updated_at_extraction_jobs ON public.extraction_jobs;
CREATE TRIGGER set_updated_at_extraction_jobs
BEFORE UPDATE ON public.extraction_jobs
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

CREATE OR REPLACE FUNCTION public.prune_user_activity_events(p_retention_days INTEGER DEFAULT 90)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deleted INTEGER;
BEGIN
  DELETE FROM public.user_activity_events
  WHERE created_at < NOW() - make_interval(days => GREATEST(COALESCE(p_retention_days, 90), 1));

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION public.prune_user_activity_events(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.prune_user_activity_events(INTEGER) TO service_role;

SELECT cron.schedule(
  'prune-user-activity-events',
  '15 2 * * *',
  $$SELECT public.prune_user_activity_events(90);$$
);

-- =========================================================
-- Signup trigger: auth.users -> organizations + profiles
-- =========================================================

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
BEGIN
  v_org_name := COALESCE(NULLIF(TRIM(NEW.raw_user_meta_data ->> 'organization_name'), ''), 'Nuova organizzazione');
  v_full_name := NULLIF(TRIM(NEW.raw_user_meta_data ->> 'full_name'), '');

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

-- =========================================================
-- Supplier name denormalization sync
-- =========================================================

CREATE OR REPLACE FUNCTION public.sync_supplier_name_to_agreement_items()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.name IS DISTINCT FROM NEW.name THEN
    UPDATE public.agreement_items ai
    SET supplier_name = NEW.name
    FROM public.agreements a
    WHERE a.supplier_id = NEW.id
      AND ai.agreement_id = a.id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.sync_supplier_name_to_invoice_items()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.name IS DISTINCT FROM NEW.name THEN
    UPDATE public.invoice_items ii
    SET supplier_name = NEW.name
    FROM public.invoices i
    WHERE i.supplier_id = NEW.id
      AND ii.invoice_id = i.id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_sync_supplier_name_agreement_items ON public.suppliers;
CREATE TRIGGER trigger_sync_supplier_name_agreement_items
AFTER UPDATE ON public.suppliers
FOR EACH ROW
EXECUTE FUNCTION public.sync_supplier_name_to_agreement_items();

DROP TRIGGER IF EXISTS trigger_sync_supplier_name_invoice_items ON public.suppliers;
CREATE TRIGGER trigger_sync_supplier_name_invoice_items
AFTER UPDATE ON public.suppliers
FOR EACH ROW
EXECUTE FUNCTION public.sync_supplier_name_to_invoice_items();

-- =========================================================
-- Agreement atomic update RPC
-- =========================================================

CREATE OR REPLACE FUNCTION public.normalize_item_name(item_name TEXT)
RETURNS TEXT
LANGUAGE SQL
IMMUTABLE
AS $$
  SELECT LOWER(unaccent(
    regexp_replace(
      regexp_replace(COALESCE(item_name, ''), '[^a-zA-Z0-9\\s]', '', 'g'),
      '\\s+', ' ', 'g'
    )
  ));
$$;

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
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb))
  LOOP
    IF v_item->>'item_name' IS NULL OR TRIM(v_item->>'item_name') = '' THEN
      RAISE EXCEPTION 'All items must have a valid name';
    END IF;
    IF v_item->>'unit_price' IS NULL OR NOT (v_item->>'unit_price' ~ '^[0-9]+(\\.[0-9]+)?$') THEN
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
    item_code,
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
    NULLIF(TRIM(item->>'item_code'), ''),
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
-- Analytics RPCs
-- =========================================================

CREATE OR REPLACE FUNCTION public.get_overcharge_by_supplier_category(
  p_organization_id UUID,
  p_month_start TIMESTAMP,
  p_year_start TIMESTAMP
)
RETURNS TABLE(
  supplier_name TEXT,
  category TEXT,
  total_overcharge_month DECIMAL,
  total_overcharge_ytd DECIMAL
)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  SELECT
    COALESCE(s.name, 'Sconosciuto') AS supplier_name,
    COALESCE(ri.category, 'Non categorizzato') AS category,
    COALESCE(SUM(CASE WHEN r.created_at >= p_month_start THEN ri.total_overcharge ELSE 0 END), 0) AS total_overcharge_month,
    COALESCE(SUM(CASE WHEN r.created_at >= p_year_start THEN ri.total_overcharge ELSE 0 END), 0) AS total_overcharge_ytd
  FROM public.report_items ri
  INNER JOIN public.reports r ON ri.report_id = r.id
  LEFT JOIN public.suppliers s ON r.supplier_id = s.id
  WHERE r.organization_id = p_organization_id
    AND ri.total_overcharge > 0
    AND r.created_at >= p_year_start
  GROUP BY s.name, ri.category
  ORDER BY total_overcharge_ytd DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_overcharge_by_supplier(
  p_organization_id UUID,
  p_month_start TIMESTAMP,
  p_year_start TIMESTAMP
)
RETURNS TABLE(
  supplier_name TEXT,
  total_overcharge_month DECIMAL,
  total_overcharge_ytd DECIMAL
)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  SELECT
    COALESCE(s.name, 'Sconosciuto') AS supplier_name,
    COALESCE(SUM(CASE WHEN r.created_at >= p_month_start THEN ri.total_overcharge ELSE 0 END), 0) AS total_overcharge_month,
    COALESCE(SUM(CASE WHEN r.created_at >= p_year_start THEN ri.total_overcharge ELSE 0 END), 0) AS total_overcharge_ytd
  FROM public.report_items ri
  INNER JOIN public.reports r ON ri.report_id = r.id
  LEFT JOIN public.suppliers s ON r.supplier_id = s.id
  WHERE r.organization_id = p_organization_id
    AND ri.total_overcharge > 0
    AND r.created_at >= p_year_start
  GROUP BY s.name
  ORDER BY total_overcharge_ytd DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_items_overcharge_count(
  p_organization_id UUID,
  p_month_start TIMESTAMP,
  p_year_start TIMESTAMP
)
RETURNS TABLE(
  supplier_name TEXT,
  items_count_month BIGINT,
  items_count_ytd BIGINT
)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  SELECT
    COALESCE(s.name, 'Sconosciuto') AS supplier_name,
    COUNT(CASE WHEN r.created_at >= p_month_start AND ri.total_overcharge > 0 THEN 1 END) AS items_count_month,
    COUNT(CASE WHEN r.created_at >= p_year_start AND ri.total_overcharge > 0 THEN 1 END) AS items_count_ytd
  FROM public.reports r
  LEFT JOIN public.suppliers s ON r.supplier_id = s.id
  LEFT JOIN public.report_items ri ON ri.report_id = r.id
  WHERE r.organization_id = p_organization_id
    AND r.created_at >= p_year_start
  GROUP BY s.name
  HAVING COUNT(CASE WHEN ri.total_overcharge > 0 THEN 1 END) > 0
  ORDER BY items_count_ytd DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_top_items_by_value(
  p_organization_id UUID,
  p_year_start TIMESTAMP,
  p_limit INT DEFAULT 5
)
RETURNS TABLE(
  item_name TEXT,
  supplier_name TEXT,
  total_overcharge DECIMAL,
  occurrences BIGINT
)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  SELECT
    ri.item_name_invoice AS item_name,
    COALESCE(s.name, 'Sconosciuto') AS supplier_name,
    SUM(ri.total_overcharge) AS total_overcharge,
    COUNT(*) AS occurrences
  FROM public.report_items ri
  INNER JOIN public.reports r ON ri.report_id = r.id
  LEFT JOIN public.suppliers s ON r.supplier_id = s.id
  WHERE r.organization_id = p_organization_id
    AND ri.total_overcharge > 0
    AND r.created_at >= p_year_start
  GROUP BY ri.item_name_invoice, s.name
  ORDER BY total_overcharge DESC
  LIMIT p_limit;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_top_items_by_frequency(
  p_organization_id UUID,
  p_year_start TIMESTAMP,
  p_limit INT DEFAULT 5
)
RETURNS TABLE(
  item_name TEXT,
  supplier_name TEXT,
  occurrences BIGINT,
  total_overcharge DECIMAL
)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  SELECT
    ri.item_name_invoice AS item_name,
    COALESCE(s.name, 'Sconosciuto') AS supplier_name,
    COUNT(*) AS occurrences,
    SUM(ri.total_overcharge) AS total_overcharge
  FROM public.report_items ri
  INNER JOIN public.reports r ON ri.report_id = r.id
  LEFT JOIN public.suppliers s ON r.supplier_id = s.id
  WHERE r.organization_id = p_organization_id
    AND ri.total_overcharge > 0
    AND r.created_at >= p_year_start
  GROUP BY ri.item_name_invoice, s.name
  ORDER BY occurrences DESC
  LIMIT p_limit;
END;
$$;

-- =========================================================
-- Distributed rate limiter RPC
-- =========================================================

CREATE OR REPLACE FUNCTION public.check_api_rate_limit(
  p_identifier TEXT,
  p_scope TEXT,
  p_max_requests INTEGER,
  p_window_seconds INTEGER
)
RETURNS TABLE(
  allowed BOOLEAN,
  remaining INTEGER,
  reset_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_now TIMESTAMPTZ := NOW();
  v_count INTEGER;
  v_window_end TIMESTAMPTZ;
BEGIN
  IF p_identifier IS NULL OR LENGTH(TRIM(p_identifier)) = 0 THEN
    RAISE EXCEPTION 'identifier is required';
  END IF;

  IF p_scope IS NULL OR LENGTH(TRIM(p_scope)) = 0 THEN
    RAISE EXCEPTION 'scope is required';
  END IF;

  IF p_max_requests <= 0 OR p_window_seconds <= 0 THEN
    RAISE EXCEPTION 'invalid rate limit parameters';
  END IF;

  INSERT INTO public.api_rate_limits (
    scope,
    identifier,
    count,
    window_start,
    window_end
  ) VALUES (
    p_scope,
    p_identifier,
    1,
    v_now,
    v_now + make_interval(secs => p_window_seconds)
  )
  ON CONFLICT (scope, identifier)
  DO UPDATE
  SET
    count = CASE
      WHEN public.api_rate_limits.window_end <= v_now THEN 1
      ELSE public.api_rate_limits.count + 1
    END,
    window_start = CASE
      WHEN public.api_rate_limits.window_end <= v_now THEN v_now
      ELSE public.api_rate_limits.window_start
    END,
    window_end = CASE
      WHEN public.api_rate_limits.window_end <= v_now THEN v_now + make_interval(secs => p_window_seconds)
      ELSE public.api_rate_limits.window_end
    END
  RETURNING count, window_end INTO v_count, v_window_end;

  RETURN QUERY
  SELECT
    v_count <= p_max_requests AS allowed,
    GREATEST(p_max_requests - v_count, 0) AS remaining,
    v_window_end AS reset_at;
END;
$$;

-- =========================================================
-- RLS helpers
-- =========================================================

CREATE OR REPLACE FUNCTION public.current_organization_id()
RETURNS UUID
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT organization_id
  FROM public.profiles
  WHERE id = auth.uid()
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.is_current_user_admin()
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE((
    SELECT role = 'admin'
    FROM public.profiles
    WHERE id = auth.uid()
    LIMIT 1
  ), FALSE);
$$;

-- =========================================================
-- Row Level Security
-- =========================================================

ALTER TABLE public.organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agreements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agreement_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invoice_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.report_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.confirmed_supplier_matches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_activity_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.extraction_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.api_rate_limits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.organization_audit_log ENABLE ROW LEVEL SECURITY;

-- organizations
DROP POLICY IF EXISTS organizations_select_authenticated ON public.organizations;
CREATE POLICY organizations_select_authenticated
ON public.organizations
FOR SELECT
TO authenticated
USING (id = public.current_organization_id());

DROP POLICY IF EXISTS organizations_update_admin ON public.organizations;
CREATE POLICY organizations_update_admin
ON public.organizations
FOR UPDATE
TO authenticated
USING (id = public.current_organization_id() AND public.is_current_user_admin())
WITH CHECK (id = public.current_organization_id() AND public.is_current_user_admin());

DROP POLICY IF EXISTS organizations_service_role_all ON public.organizations;
CREATE POLICY organizations_service_role_all
ON public.organizations
FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

-- profiles
DROP POLICY IF EXISTS profiles_select_same_org ON public.profiles;
CREATE POLICY profiles_select_same_org
ON public.profiles
FOR SELECT
TO authenticated
USING (organization_id = public.current_organization_id());

DROP POLICY IF EXISTS profiles_update_self_or_admin ON public.profiles;
CREATE POLICY profiles_update_self_or_admin
ON public.profiles
FOR UPDATE
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND (id = auth.uid() OR public.is_current_user_admin())
)
WITH CHECK (
  organization_id = public.current_organization_id()
  AND (id = auth.uid() OR public.is_current_user_admin())
);

DROP POLICY IF EXISTS profiles_service_role_all ON public.profiles;
CREATE POLICY profiles_service_role_all
ON public.profiles
FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

-- suppliers
DROP POLICY IF EXISTS suppliers_select_same_org ON public.suppliers;
CREATE POLICY suppliers_select_same_org
ON public.suppliers
FOR SELECT
TO authenticated
USING (organization_id = public.current_organization_id());

DROP POLICY IF EXISTS suppliers_insert_admin ON public.suppliers;
CREATE POLICY suppliers_insert_admin
ON public.suppliers
FOR INSERT
TO authenticated
WITH CHECK (
  organization_id = public.current_organization_id()
  AND public.is_current_user_admin()
);

DROP POLICY IF EXISTS suppliers_update_admin ON public.suppliers;
CREATE POLICY suppliers_update_admin
ON public.suppliers
FOR UPDATE
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND public.is_current_user_admin()
)
WITH CHECK (
  organization_id = public.current_organization_id()
  AND public.is_current_user_admin()
);

DROP POLICY IF EXISTS suppliers_delete_admin ON public.suppliers;
CREATE POLICY suppliers_delete_admin
ON public.suppliers
FOR DELETE
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND public.is_current_user_admin()
);

DROP POLICY IF EXISTS suppliers_service_role_all ON public.suppliers;
CREATE POLICY suppliers_service_role_all
ON public.suppliers
FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

-- agreements
DROP POLICY IF EXISTS agreements_select_same_org ON public.agreements;
CREATE POLICY agreements_select_same_org
ON public.agreements
FOR SELECT
TO authenticated
USING (organization_id = public.current_organization_id());

DROP POLICY IF EXISTS agreements_insert_admin ON public.agreements;
CREATE POLICY agreements_insert_admin
ON public.agreements
FOR INSERT
TO authenticated
WITH CHECK (
  organization_id = public.current_organization_id()
  AND public.is_current_user_admin()
);

DROP POLICY IF EXISTS agreements_update_admin ON public.agreements;
CREATE POLICY agreements_update_admin
ON public.agreements
FOR UPDATE
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND public.is_current_user_admin()
)
WITH CHECK (
  organization_id = public.current_organization_id()
  AND public.is_current_user_admin()
);

DROP POLICY IF EXISTS agreements_delete_admin ON public.agreements;
CREATE POLICY agreements_delete_admin
ON public.agreements
FOR DELETE
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND public.is_current_user_admin()
);

DROP POLICY IF EXISTS agreements_service_role_all ON public.agreements;
CREATE POLICY agreements_service_role_all
ON public.agreements
FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

-- agreement_items
DROP POLICY IF EXISTS agreement_items_select_same_org ON public.agreement_items;
CREATE POLICY agreement_items_select_same_org
ON public.agreement_items
FOR SELECT
TO authenticated
USING (organization_id = public.current_organization_id());

DROP POLICY IF EXISTS agreement_items_insert_admin ON public.agreement_items;
CREATE POLICY agreement_items_insert_admin
ON public.agreement_items
FOR INSERT
TO authenticated
WITH CHECK (
  organization_id = public.current_organization_id()
  AND public.is_current_user_admin()
);

DROP POLICY IF EXISTS agreement_items_update_admin ON public.agreement_items;
CREATE POLICY agreement_items_update_admin
ON public.agreement_items
FOR UPDATE
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND public.is_current_user_admin()
)
WITH CHECK (
  organization_id = public.current_organization_id()
  AND public.is_current_user_admin()
);

DROP POLICY IF EXISTS agreement_items_delete_admin ON public.agreement_items;
CREATE POLICY agreement_items_delete_admin
ON public.agreement_items
FOR DELETE
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND public.is_current_user_admin()
);

DROP POLICY IF EXISTS agreement_items_service_role_all ON public.agreement_items;
CREATE POLICY agreement_items_service_role_all
ON public.agreement_items
FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

-- invoices
DROP POLICY IF EXISTS invoices_select_same_org ON public.invoices;
CREATE POLICY invoices_select_same_org
ON public.invoices
FOR SELECT
TO authenticated
USING (organization_id = public.current_organization_id());

DROP POLICY IF EXISTS invoices_insert_same_org ON public.invoices;
CREATE POLICY invoices_insert_same_org
ON public.invoices
FOR INSERT
TO authenticated
WITH CHECK (organization_id = public.current_organization_id());

DROP POLICY IF EXISTS invoices_update_same_org ON public.invoices;
CREATE POLICY invoices_update_same_org
ON public.invoices
FOR UPDATE
TO authenticated
USING (organization_id = public.current_organization_id())
WITH CHECK (organization_id = public.current_organization_id());

DROP POLICY IF EXISTS invoices_delete_same_org ON public.invoices;
CREATE POLICY invoices_delete_same_org
ON public.invoices
FOR DELETE
TO authenticated
USING (organization_id = public.current_organization_id());

DROP POLICY IF EXISTS invoices_service_role_all ON public.invoices;
CREATE POLICY invoices_service_role_all
ON public.invoices
FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

-- invoice_items
DROP POLICY IF EXISTS invoice_items_select_same_org ON public.invoice_items;
CREATE POLICY invoice_items_select_same_org
ON public.invoice_items
FOR SELECT
TO authenticated
USING (organization_id = public.current_organization_id());

DROP POLICY IF EXISTS invoice_items_insert_same_org ON public.invoice_items;
CREATE POLICY invoice_items_insert_same_org
ON public.invoice_items
FOR INSERT
TO authenticated
WITH CHECK (organization_id = public.current_organization_id());

DROP POLICY IF EXISTS invoice_items_update_same_org ON public.invoice_items;
CREATE POLICY invoice_items_update_same_org
ON public.invoice_items
FOR UPDATE
TO authenticated
USING (organization_id = public.current_organization_id())
WITH CHECK (organization_id = public.current_organization_id());

DROP POLICY IF EXISTS invoice_items_delete_same_org ON public.invoice_items;
CREATE POLICY invoice_items_delete_same_org
ON public.invoice_items
FOR DELETE
TO authenticated
USING (organization_id = public.current_organization_id());

DROP POLICY IF EXISTS invoice_items_service_role_all ON public.invoice_items;
CREATE POLICY invoice_items_service_role_all
ON public.invoice_items
FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

-- reports
DROP POLICY IF EXISTS reports_select_same_org ON public.reports;
CREATE POLICY reports_select_same_org
ON public.reports
FOR SELECT
TO authenticated
USING (organization_id = public.current_organization_id());

DROP POLICY IF EXISTS reports_insert_same_org ON public.reports;
CREATE POLICY reports_insert_same_org
ON public.reports
FOR INSERT
TO authenticated
WITH CHECK (organization_id = public.current_organization_id());

DROP POLICY IF EXISTS reports_update_same_org ON public.reports;
CREATE POLICY reports_update_same_org
ON public.reports
FOR UPDATE
TO authenticated
USING (organization_id = public.current_organization_id())
WITH CHECK (organization_id = public.current_organization_id());

DROP POLICY IF EXISTS reports_delete_same_org ON public.reports;
CREATE POLICY reports_delete_same_org
ON public.reports
FOR DELETE
TO authenticated
USING (organization_id = public.current_organization_id());

DROP POLICY IF EXISTS reports_service_role_all ON public.reports;
CREATE POLICY reports_service_role_all
ON public.reports
FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

-- report_items
DROP POLICY IF EXISTS report_items_select_same_org ON public.report_items;
CREATE POLICY report_items_select_same_org
ON public.report_items
FOR SELECT
TO authenticated
USING (organization_id = public.current_organization_id());

DROP POLICY IF EXISTS report_items_insert_same_org ON public.report_items;
CREATE POLICY report_items_insert_same_org
ON public.report_items
FOR INSERT
TO authenticated
WITH CHECK (organization_id = public.current_organization_id());

DROP POLICY IF EXISTS report_items_update_same_org ON public.report_items;
CREATE POLICY report_items_update_same_org
ON public.report_items
FOR UPDATE
TO authenticated
USING (organization_id = public.current_organization_id())
WITH CHECK (organization_id = public.current_organization_id());

DROP POLICY IF EXISTS report_items_delete_same_org ON public.report_items;
CREATE POLICY report_items_delete_same_org
ON public.report_items
FOR DELETE
TO authenticated
USING (organization_id = public.current_organization_id());

DROP POLICY IF EXISTS report_items_service_role_all ON public.report_items;
CREATE POLICY report_items_service_role_all
ON public.report_items
FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

-- confirmed_supplier_matches
DROP POLICY IF EXISTS confirmed_supplier_matches_select_same_org ON public.confirmed_supplier_matches;
CREATE POLICY confirmed_supplier_matches_select_same_org
ON public.confirmed_supplier_matches
FOR SELECT
TO authenticated
USING (organization_id = public.current_organization_id());

DROP POLICY IF EXISTS confirmed_supplier_matches_insert_same_org ON public.confirmed_supplier_matches;
CREATE POLICY confirmed_supplier_matches_insert_same_org
ON public.confirmed_supplier_matches
FOR INSERT
TO authenticated
WITH CHECK (organization_id = public.current_organization_id());

DROP POLICY IF EXISTS confirmed_supplier_matches_update_same_org ON public.confirmed_supplier_matches;
CREATE POLICY confirmed_supplier_matches_update_same_org
ON public.confirmed_supplier_matches
FOR UPDATE
TO authenticated
USING (organization_id = public.current_organization_id())
WITH CHECK (organization_id = public.current_organization_id());

DROP POLICY IF EXISTS confirmed_supplier_matches_delete_same_org ON public.confirmed_supplier_matches;
CREATE POLICY confirmed_supplier_matches_delete_same_org
ON public.confirmed_supplier_matches
FOR DELETE
TO authenticated
USING (organization_id = public.current_organization_id());

DROP POLICY IF EXISTS confirmed_supplier_matches_service_role_all ON public.confirmed_supplier_matches;
CREATE POLICY confirmed_supplier_matches_service_role_all
ON public.confirmed_supplier_matches
FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

-- audit_logs
DROP POLICY IF EXISTS audit_logs_select_same_org ON public.audit_logs;
CREATE POLICY audit_logs_select_same_org
ON public.audit_logs
FOR SELECT
TO authenticated
USING (organization_id = public.current_organization_id());

DROP POLICY IF EXISTS audit_logs_insert_same_org ON public.audit_logs;
CREATE POLICY audit_logs_insert_same_org
ON public.audit_logs
FOR INSERT
TO authenticated
WITH CHECK (organization_id = public.current_organization_id());

DROP POLICY IF EXISTS audit_logs_service_role_all ON public.audit_logs;
CREATE POLICY audit_logs_service_role_all
ON public.audit_logs
FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

-- user_activity_events
DROP POLICY IF EXISTS user_activity_events_service_role_all ON public.user_activity_events;
CREATE POLICY user_activity_events_service_role_all
ON public.user_activity_events
FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

REVOKE ALL ON TABLE public.user_activity_events FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.user_activity_events TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.user_activity_events_id_seq TO service_role;

-- extraction_jobs
DROP POLICY IF EXISTS extraction_jobs_select_owner ON public.extraction_jobs;
CREATE POLICY extraction_jobs_select_owner
ON public.extraction_jobs
FOR SELECT
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND user_id = auth.uid()
);

DROP POLICY IF EXISTS extraction_jobs_insert_owner ON public.extraction_jobs;
CREATE POLICY extraction_jobs_insert_owner
ON public.extraction_jobs
FOR INSERT
TO authenticated
WITH CHECK (
  organization_id = public.current_organization_id()
  AND user_id = auth.uid()
);

DROP POLICY IF EXISTS extraction_jobs_update_owner ON public.extraction_jobs;
CREATE POLICY extraction_jobs_update_owner
ON public.extraction_jobs
FOR UPDATE
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND user_id = auth.uid()
)
WITH CHECK (
  organization_id = public.current_organization_id()
  AND user_id = auth.uid()
);

DROP POLICY IF EXISTS extraction_jobs_delete_owner ON public.extraction_jobs;
CREATE POLICY extraction_jobs_delete_owner
ON public.extraction_jobs
FOR DELETE
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND user_id = auth.uid()
);

DROP POLICY IF EXISTS extraction_jobs_service_role_all ON public.extraction_jobs;
CREATE POLICY extraction_jobs_service_role_all
ON public.extraction_jobs
FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

-- api_rate_limits
DROP POLICY IF EXISTS api_rate_limits_service_role_all ON public.api_rate_limits;
CREATE POLICY api_rate_limits_service_role_all
ON public.api_rate_limits
FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

-- organization_audit_log
DROP POLICY IF EXISTS organization_audit_log_select_same_org ON public.organization_audit_log;
CREATE POLICY organization_audit_log_select_same_org
ON public.organization_audit_log
FOR SELECT
TO authenticated
USING (organization_id = public.current_organization_id());

DROP POLICY IF EXISTS organization_audit_log_insert_same_org ON public.organization_audit_log;
CREATE POLICY organization_audit_log_insert_same_org
ON public.organization_audit_log
FOR INSERT
TO authenticated
WITH CHECK (
  organization_id = public.current_organization_id()
  AND user_id = auth.uid()
);

DROP POLICY IF EXISTS organization_audit_log_service_role_all ON public.organization_audit_log;
CREATE POLICY organization_audit_log_service_role_all
ON public.organization_audit_log
FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

-- =========================================================
-- Permissions
-- =========================================================

REVOKE ALL ON SCHEMA public FROM anon;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon;

GRANT USAGE ON SCHEMA public TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated, service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated, service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated, service_role;

GRANT USAGE ON SCHEMA storage TO authenticated, service_role;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA storage TO authenticated, service_role;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA storage TO authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
GRANT USAGE, SELECT ON SEQUENCES TO authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
GRANT EXECUTE ON FUNCTIONS TO authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA storage
GRANT ALL ON TABLES TO authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA storage
GRANT ALL ON SEQUENCES TO authenticated, service_role;

-- Ensure a schema cache reload for PostgREST when it starts.
SELECT pg_notify('pgrst', 'reload schema');

COMMIT;
