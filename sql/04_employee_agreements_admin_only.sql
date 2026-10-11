-- Migration: enforce admin-only writes on agreements and agreement items
-- Date: 2026-03-04

-- =========================================================
-- Harden RPC: only organization admins can update agreements with items
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
-- RLS: employees cannot update/delete agreements or items
-- =========================================================

DROP POLICY IF EXISTS agreements_update_managed ON public.agreements;
CREATE POLICY agreements_update_managed
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

DROP POLICY IF EXISTS agreements_delete_managed ON public.agreements;
CREATE POLICY agreements_delete_managed
ON public.agreements
FOR DELETE
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND public.is_current_user_admin()
);

DROP POLICY IF EXISTS agreement_items_update_managed ON public.agreement_items;
CREATE POLICY agreement_items_update_managed
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

DROP POLICY IF EXISTS agreement_items_delete_managed ON public.agreement_items;
CREATE POLICY agreement_items_delete_managed
ON public.agreement_items
FOR DELETE
TO authenticated
USING (
  organization_id = public.current_organization_id()
  AND public.is_current_user_admin()
);
