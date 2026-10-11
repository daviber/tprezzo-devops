-- Migration: Stripe billing hardening
-- Date: 2026-05-01
--
-- Goals:
-- 1) Prevent authenticated clients from mutating billing/subscription fields directly.
-- 2) Track Stripe Checkout Sessions to avoid parallel subscriptions for one organization.
-- 3) Track processed Stripe webhook events for idempotent webhook handling.

-- =========================================================
-- Stripe webhook idempotency
-- =========================================================

CREATE TABLE IF NOT EXISTS public.stripe_webhook_events (
  event_id TEXT PRIMARY KEY,
  event_type TEXT NOT NULL,
  object_id TEXT,
  processing_status TEXT NOT NULL DEFAULT 'processing' CHECK (
    processing_status IN ('processing', 'processed', 'failed')
  ),
  error_message TEXT,
  received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  processed_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_stripe_webhook_events_status
  ON public.stripe_webhook_events (processing_status, received_at);

ALTER TABLE public.stripe_webhook_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS stripe_webhook_events_service_role_all ON public.stripe_webhook_events;
CREATE POLICY stripe_webhook_events_service_role_all
ON public.stripe_webhook_events
FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

REVOKE ALL ON TABLE public.stripe_webhook_events FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.stripe_webhook_events TO service_role;

-- =========================================================
-- Stripe Checkout Session guard
-- =========================================================

CREATE TABLE IF NOT EXISTS public.stripe_checkout_sessions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  checkout_session_id TEXT UNIQUE,
  stripe_customer_id TEXT,
  target_tier TEXT NOT NULL CHECK (target_tier IN ('base', 'premium')),
  idempotency_key TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL DEFAULT 'creating' CHECK (
    status IN ('creating', 'pending', 'completed', 'expired', 'cancelled', 'failed')
  ),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_stripe_checkout_sessions_one_open_per_org
  ON public.stripe_checkout_sessions (organization_id)
  WHERE status IN ('creating', 'pending');

CREATE INDEX IF NOT EXISTS idx_stripe_checkout_sessions_session_id
  ON public.stripe_checkout_sessions (checkout_session_id)
  WHERE checkout_session_id IS NOT NULL;

ALTER TABLE public.stripe_checkout_sessions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS stripe_checkout_sessions_service_role_all ON public.stripe_checkout_sessions;
CREATE POLICY stripe_checkout_sessions_service_role_all
ON public.stripe_checkout_sessions
FOR ALL
TO service_role
USING (TRUE)
WITH CHECK (TRUE);

REVOKE ALL ON TABLE public.stripe_checkout_sessions FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.stripe_checkout_sessions TO service_role;

-- =========================================================
-- Organizations billing-field protection
-- =========================================================

CREATE OR REPLACE FUNCTION public.protect_organization_billing_fields()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.role() = 'authenticated' THEN
    IF NEW.subscription_tier IS DISTINCT FROM OLD.subscription_tier
      OR NEW.subscription_status IS DISTINCT FROM OLD.subscription_status
      OR NEW.stripe_customer_id IS DISTINCT FROM OLD.stripe_customer_id
      OR NEW.stripe_subscription_id IS DISTINCT FROM OLD.stripe_subscription_id
      OR NEW.stripe_price_id IS DISTINCT FROM OLD.stripe_price_id
      OR NEW.stripe_current_period_start IS DISTINCT FROM OLD.stripe_current_period_start
      OR NEW.stripe_current_period_end IS DISTINCT FROM OLD.stripe_current_period_end
      OR NEW.subscription_cancel_at_period_end IS DISTINCT FROM OLD.subscription_cancel_at_period_end
      OR NEW.subscription_manual_sync_last_at IS DISTINCT FROM OLD.subscription_manual_sync_last_at
      OR NEW.max_users IS DISTINCT FROM OLD.max_users THEN
      RAISE EXCEPTION 'Billing fields cannot be changed directly';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS protect_organization_billing_fields ON public.organizations;
CREATE TRIGGER protect_organization_billing_fields
BEFORE UPDATE ON public.organizations
FOR EACH ROW
EXECUTE FUNCTION public.protect_organization_billing_fields();

REVOKE INSERT, UPDATE, DELETE ON TABLE public.organizations FROM authenticated;
GRANT SELECT ON TABLE public.organizations TO authenticated;
GRANT UPDATE (name, updated_at) ON TABLE public.organizations TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.organizations TO service_role;
