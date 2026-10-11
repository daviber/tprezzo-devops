-- Migration: manual subscription sync cooldown tracking
-- Date: 2026-03-06

ALTER TABLE public.organizations
  ADD COLUMN IF NOT EXISTS subscription_manual_sync_last_at TIMESTAMPTZ;
