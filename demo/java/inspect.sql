-- Inventory only: run manually in Supabase SQL Editor or an approved SQL session.
-- No credentials, documents, user identities or lease tokens are returned.
-- No application RPC is invoked; function presence is not proof of full parity.
-- Missing relations make their later queries fail closed; install/review schema
-- separately. This script never applies migrations or repairs/cancels jobs.
BEGIN TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '15s';
SET LOCAL lock_timeout = '2s';

SELECT current_timestamp AS inspected_at,
       current_setting('transaction_read_only') AS read_only;

-- J03 prerequisites and async schema, using catalog metadata only.
WITH expected(relation_name) AS (
  VALUES ('auth.users'), ('auth.sessions'), ('public.organizations'),
         ('public.profiles'), ('public.employee_supplier_visibility'),
         ('public.platform_plan_settings'), ('public.price_centric_jobs'),
         ('public.price_centric_job_subscribers')
)
SELECT relation_name, to_regclass(relation_name) IS NOT NULL AS installed
FROM expected
ORDER BY relation_name;

WITH expected(function_name) AS (
  VALUES ('handle_new_user'), ('tprezzo_provision_invited_account'),
         ('enqueue_price_centric_job_for_user'),
         ('list_price_centric_jobs_for_current_user'),
         ('claim_price_centric_jobs'), ('renew_price_centric_job_lease'),
         ('update_price_centric_job_progress'), ('complete_price_centric_job'),
         ('fail_or_retry_price_centric_job'), ('recover_expired_price_centric_jobs'),
         ('cancel_expired_pending_price_centric_jobs'),
         ('cancel_pending_price_centric_job_for_user'),
         ('lock_price_centric_worker_lease'), ('assert_price_centric_worker_row_scope'),
         ('enforce_price_centric_worker_row_scope')
)
SELECT expected.function_name,
       p.oid IS NOT NULL AS installed,
       pg_get_function_identity_arguments(p.oid) AS arguments,
       p.prosecdef AS security_definer,
       ARRAY(SELECT setting FROM unnest(p.proconfig) AS setting
             WHERE setting LIKE 'search_path=%') AS search_path_settings
FROM expected
LEFT JOIN pg_namespace AS n ON n.nspname = 'public'
LEFT JOIN pg_proc AS p ON p.pronamespace = n.oid AND p.proname = expected.function_name
ORDER BY expected.function_name, arguments;

-- J03 exact signature plus execute permissions; no provisioning call.
WITH rpc AS (
  SELECT to_regprocedure('public.tprezzo_provision_invited_account(uuid,uuid)') AS oid
), expected(role_name) AS (
  VALUES ('service_role'), ('anon'), ('authenticated')
)
SELECT expected.role_name,
       rpc.oid IS NOT NULL AS exact_signature_installed,
       CASE WHEN rpc.oid IS NOT NULL AND r.oid IS NOT NULL
            THEN has_function_privilege(r.oid, rpc.oid, 'EXECUTE')
            ELSE NULL END AS can_execute
FROM expected
CROSS JOIN rpc
LEFT JOIN pg_roles AS r ON r.rolname = expected.role_name
ORDER BY expected.role_name;

-- The deferral guard marker is an inspection hint, not a source equivalence check.
SELECT p.oid IS NOT NULL AS onboarding_function_installed,
       COALESCE(position('tprezzo_invitation' IN p.prosrc) > 0, false) AS invitation_marker_present,
       COALESCE(position('invited_by' IN p.prosrc) > 0, false) AS inviter_marker_present,
       EXISTS (
         SELECT 1 FROM pg_trigger AS t
         WHERE t.tgrelid = to_regclass('auth.users')
           AND t.tgname = 'on_auth_user_created'
           AND t.tgfoid = p.oid
           AND NOT t.tgisinternal
           AND t.tgenabled IN ('O', 'A')
       ) AS onboarding_trigger_enabled
FROM (SELECT to_regprocedure('public.handle_new_user()') AS oid) AS expected
LEFT JOIN pg_proc AS p ON p.oid = expected.oid;

-- Validate the columns used by the inventory before querying queue contents.
WITH expected(column_name) AS (
  VALUES ('instance_id'), ('status'), ('attempts'), ('available_at'),
         ('locked_by'), ('lease_token'), ('lock_expires_at'),
         ('started_at'), ('created_at')
)
SELECT expected.column_name,
       c.column_name IS NOT NULL AS installed,
       c.data_type
FROM expected
LEFT JOIN information_schema.columns AS c
  ON c.table_schema = 'public' AND c.table_name = 'price_centric_jobs'
 AND c.column_name = expected.column_name
ORDER BY expected.column_name;

-- All known states are shown even when empty. Keep the existing demo instance ID
-- during cutover so prior S3 references remain readable.
WITH settings AS (SELECT 'demo-hetzner-eu1'::text AS instance_id),
states(status) AS (
  VALUES ('pending'), ('processing'), ('completed'), ('failed'), ('cancelled')
)
SELECT settings.instance_id, states.status, count(j.status) AS jobs
FROM settings
CROSS JOIN states
LEFT JOIN public.price_centric_jobs AS j
  ON j.instance_id = settings.instance_id AND j.status = states.status
GROUP BY settings.instance_id, states.status
ORDER BY states.status;

-- Java recovery passes a fixed pending timeout of 300 seconds. New jobs with
-- attempts=0 and started_at IS NULL may be cancelled after five minutes even
-- when the worker is healthy but busy. Retries are excluded from that rule.
SELECT instance_id,
       count(*) FILTER (WHERE status = 'pending') AS pending,
       count(*) FILTER (WHERE status = 'pending' AND available_at <= current_timestamp) AS ready_pending,
       count(*) FILTER (
         WHERE status = 'pending' AND attempts = 0 AND started_at IS NULL
           AND created_at <= current_timestamp - interval '300 seconds'
       ) AS pending_at_cancellation_risk,
       count(*) FILTER (WHERE status = 'processing') AS processing,
       count(*) FILTER (
         WHERE status = 'processing' AND locked_by IS NOT NULL
           AND lease_token IS NOT NULL AND lock_expires_at > current_timestamp
       ) AS active_leases,
       count(*) FILTER (
         WHERE status = 'processing' AND lock_expires_at <= current_timestamp
       ) AS expired_leases,
       max(extract(epoch FROM current_timestamp - created_at)::bigint)
         FILTER (WHERE status = 'pending') AS oldest_pending_age_seconds,
       min(lock_expires_at) FILTER (WHERE status = 'processing') AS nearest_lease_expiry
FROM public.price_centric_jobs
WHERE instance_id = 'demo-hetzner-eu1'
GROUP BY instance_id;

-- Worker mutation guards must stay enabled on their current tables.
SELECT n.nspname AS schema_name, c.relname AS table_name,
       t.tgname AS trigger_name, p.proname AS guard_function,
       t.tgenabled IN ('O', 'A') AS enabled
FROM pg_trigger AS t
JOIN pg_class AS c ON c.oid = t.tgrelid
JOIN pg_namespace AS n ON n.oid = c.relnamespace
JOIN pg_proc AS p ON p.oid = t.tgfoid
WHERE NOT t.tgisinternal AND n.nspname = 'public'
  AND p.proname IN ('lock_price_centric_worker_lease', 'enforce_price_centric_worker_row_scope')
ORDER BY c.relname, t.tgname;

ROLLBACK;
