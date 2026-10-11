-- Add subscription-cycle usage metadata and agreement monthly limits

ALTER TABLE public.organizations
  ADD COLUMN IF NOT EXISTS stripe_current_period_start TIMESTAMPTZ;

-- Backfill best-effort start date from period end when available.
UPDATE public.organizations
SET stripe_current_period_start = stripe_current_period_end - INTERVAL '1 month'
WHERE stripe_current_period_start IS NULL
  AND stripe_current_period_end IS NOT NULL;

ALTER TABLE public.platform_plan_settings
  ADD COLUMN IF NOT EXISTS max_monthly_agreements INTEGER CHECK (
    max_monthly_agreements IS NULL OR max_monthly_agreements >= 0
  );

-- Default base plan agreement limit, premium remains unlimited.
UPDATE public.platform_plan_settings
SET max_monthly_agreements = 50
WHERE tier = 'base'
  AND max_monthly_agreements IS NULL;
