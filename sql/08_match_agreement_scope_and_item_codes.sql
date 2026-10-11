-- Scope confirmed matches to the selected agreement and preserve item codes on agreement updates.

ALTER TABLE public.agreement_items
  ADD COLUMN IF NOT EXISTS item_code TEXT;

ALTER TABLE public.invoice_items
  ADD COLUMN IF NOT EXISTS item_code TEXT;

CREATE INDEX IF NOT EXISTS idx_agreement_items_code
  ON public.agreement_items(item_code)
  WHERE item_code IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_invoice_items_code
  ON public.invoice_items(item_code)
  WHERE item_code IS NOT NULL;

ALTER TABLE public.confirmed_supplier_matches
  ADD COLUMN IF NOT EXISTS agreement_id UUID;

UPDATE public.confirmed_supplier_matches csm
SET agreement_id = ai.agreement_id
FROM public.agreement_items ai
WHERE csm.agreement_item_id = ai.id
  AND csm.agreement_id IS NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'confirmed_supplier_matches_agreement_id_fkey'
      AND conrelid = 'public.confirmed_supplier_matches'::regclass
  ) THEN
    ALTER TABLE public.confirmed_supplier_matches
      ADD CONSTRAINT confirmed_supplier_matches_agreement_id_fkey
      FOREIGN KEY (agreement_id)
      REFERENCES public.agreements(id)
      ON DELETE CASCADE;
  END IF;
END
$$;

ALTER TABLE public.confirmed_supplier_matches
  ALTER COLUMN agreement_id SET NOT NULL;

ALTER TABLE public.confirmed_supplier_matches
  DROP CONSTRAINT IF EXISTS confirmed_supplier_matches_unique_key;

ALTER TABLE public.confirmed_supplier_matches
  ADD CONSTRAINT confirmed_supplier_matches_unique_key
  UNIQUE (organization_id, supplier_id, agreement_id, invoice_match_key);

CREATE INDEX IF NOT EXISTS idx_confirmed_supplier_matches_org_supplier_agreement
  ON public.confirmed_supplier_matches(organization_id, supplier_id, agreement_id);

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

  IF NOT public.is_current_user_admin() THEN
    RAISE EXCEPTION 'Access denied for agreement management';
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
