-- =============================================================================
-- DELEGATION PATTERN DETECTION QUERIES
-- Predictive Delegation Seeding Experiment
-- =============================================================================
-- These queries detect three delegation archetypes from walk_delegations data.
-- They assume the walk_delegations table is populated with delegation records.
--
-- ACTUAL SCHEMA (from foreign-keys.json):
--   walk_delegations:
--     id                  uuid  PK
--     original_tenant_id  uuid  FK -> tenants.id
--     delegate_tenant_id  uuid  FK -> tenants.id
--     proposed_by         uuid  FK -> tenants.id
--     client_id           uuid  FK -> users.id
--     walk_window_id      uuid  FK -> client_walk_windows.id
--     meet_and_greet_id   uuid  FK -> meet_and_greets.id (nullable)
--
-- INFERRED COLUMNS (needed for these queries, not yet in schema):
--     status              text  (e.g., 'proposed','accepted','active','completed','rejected')
--     created_at          timestamptz
--     accepted_at         timestamptz (nullable)
--     effective_start     date
--     effective_end       date (nullable)
--
-- NOTE: The status column and timestamps are inferred requirements.
-- The existing schema has the FK structure but may need these operational columns.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- ARCHETYPE 1: REGULAR COVERAGE
-- ─────────────────────────────────────────────────────────────────────────────
-- Pattern: Tenant A consistently delegates the SAME walk_window_id to Tenant B.
-- Detection: Look for (original_tenant_id, delegate_tenant_id, walk_window_id)
--            tuples that appear repeatedly or have long effective periods.
--
-- This is the strongest signal for predictive seeding — a stable, recurring
-- delegation relationship at the window (contract) level.
-- ─────────────────────────────────────────────────────────────────────────────

-- Query 1a: Find stable delegation pairs (same window delegated to same tenant)
SELECT
    wd.original_tenant_id,
    t_orig.slug AS original_tenant_slug,
    wd.delegate_tenant_id,
    t_del.slug AS delegate_tenant_slug,
    wd.walk_window_id,
    cww.day_of_week,
    cww.window_start,
    cww.window_end,
    COUNT(*) AS delegation_count,
    MIN(wd.created_at) AS first_delegation,
    MAX(wd.created_at) AS latest_delegation,
    -- Stability score: higher = more predictable
    -- (count * recency_weight) where recency decays over 90 days
    COUNT(*) * EXP(-EXTRACT(EPOCH FROM (NOW() - MAX(wd.created_at))) / (90 * 86400))
        AS stability_score
FROM walk_delegations wd
JOIN tenants t_orig ON t_orig.id = wd.original_tenant_id
JOIN tenants t_del  ON t_del.id  = wd.delegate_tenant_id
JOIN client_walk_windows cww ON cww.id = wd.walk_window_id
WHERE wd.status IN ('active', 'completed', 'accepted')
GROUP BY
    wd.original_tenant_id, t_orig.slug,
    wd.delegate_tenant_id, t_del.slug,
    wd.walk_window_id,
    cww.day_of_week, cww.window_start, cww.window_end
HAVING COUNT(*) >= 2  -- At least 2 delegations = pattern emerging
ORDER BY stability_score DESC;

-- Query 1b: Windows that SHOULD be delegated but haven't been yet this week
-- (Predictive gap detection — the core of "seeding before asking")
WITH regular_patterns AS (
    SELECT
        wd.original_tenant_id,
        wd.delegate_tenant_id,
        wd.walk_window_id,
        cww.day_of_week,
        COUNT(*) AS historical_count,
        MAX(wd.created_at) AS last_delegation
    FROM walk_delegations wd
    JOIN client_walk_windows cww ON cww.id = wd.walk_window_id
    WHERE wd.status IN ('active', 'completed', 'accepted')
    GROUP BY wd.original_tenant_id, wd.delegate_tenant_id,
             wd.walk_window_id, cww.day_of_week
    HAVING COUNT(*) >= 3  -- Strong pattern threshold
),
current_week_delegations AS (
    SELECT walk_window_id
    FROM walk_delegations
    WHERE created_at >= DATE_TRUNC('week', CURRENT_DATE)
      AND status NOT IN ('rejected', 'cancelled')
)
SELECT
    rp.*,
    CASE
        WHEN cwd.walk_window_id IS NULL THEN 'MISSING — suggest delegation'
        ELSE 'Already delegated this week'
    END AS prediction_action
FROM regular_patterns rp
LEFT JOIN current_week_delegations cwd
    ON cwd.walk_window_id = rp.walk_window_id
WHERE cwd.walk_window_id IS NULL  -- Only show gaps
ORDER BY rp.historical_count DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- ARCHETYPE 2: EMERGENCY HANDOFF
-- ─────────────────────────────────────────────────────────────────────────────
-- Pattern: Short-notice delegations (created_at very close to walk date).
-- Detection: Look for delegations where the gap between creation and the
--            walk window's next occurrence is < 48 hours.
--
-- NOTE: Emergency handoffs may need instance-level (walk_id) tracking,
--       not just window-level. This is a schema gap identified below.
-- ─────────────────────────────────────────────────────────────────────────────

-- Query 2a: Identify emergency delegations (< 48h notice)
SELECT
    wd.id AS delegation_id,
    wd.original_tenant_id,
    wd.delegate_tenant_id,
    wd.walk_window_id,
    wd.client_id,
    wd.created_at,
    -- Calculate urgency: how close to the next walk date was this delegation created?
    -- We approximate by finding walks linked to this window near creation time
    w.walk_date,
    EXTRACT(EPOCH FROM (w.walk_date::timestamp - wd.created_at)) / 3600 AS hours_notice,
    CASE
        WHEN EXTRACT(EPOCH FROM (w.walk_date::timestamp - wd.created_at)) / 3600 < 24
            THEN 'CRITICAL (< 24h)'
        WHEN EXTRACT(EPOCH FROM (w.walk_date::timestamp - wd.created_at)) / 3600 < 48
            THEN 'URGENT (24-48h)'
        ELSE 'PLANNED (> 48h)'
    END AS urgency_class
FROM walk_delegations wd
JOIN walks w ON w.walk_window_id = wd.walk_window_id
    AND w.walk_date >= wd.created_at::date
    AND w.walk_date <= wd.created_at::date + INTERVAL '7 days'
WHERE wd.status IN ('active', 'completed', 'accepted')
ORDER BY hours_notice ASC;

-- Query 2b: Emergency handoff frequency by tenant pair
-- (Identifies which tenant pairs have emergency relationships)
SELECT
    wd.original_tenant_id,
    wd.delegate_tenant_id,
    COUNT(*) AS total_delegations,
    COUNT(*) FILTER (
        WHERE EXTRACT(EPOCH FROM (w.walk_date::timestamp - wd.created_at)) / 3600 < 48
    ) AS emergency_count,
    ROUND(
        COUNT(*) FILTER (
            WHERE EXTRACT(EPOCH FROM (w.walk_date::timestamp - wd.created_at)) / 3600 < 48
        )::numeric / NULLIF(COUNT(*), 0) * 100, 1
    ) AS emergency_pct
FROM walk_delegations wd
JOIN walks w ON w.walk_window_id = wd.walk_window_id
    AND w.walk_date >= wd.created_at::date
    AND w.walk_date <= wd.created_at::date + INTERVAL '7 days'
WHERE wd.status IN ('active', 'completed', 'accepted')
GROUP BY wd.original_tenant_id, wd.delegate_tenant_id
HAVING COUNT(*) >= 2
ORDER BY emergency_pct DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- ARCHETYPE 3: SEASONAL OVERFLOW
-- ─────────────────────────────────────────────────────────────────────────────
-- Pattern: Delegations cluster around specific periods (holidays, summer,
--          school pickup hours). Volume spikes trigger delegation.
-- Detection: Look for delegation density patterns by month, day_of_week,
--            and time_of_day.
-- ─────────────────────────────────────────────────────────────────────────────

-- Query 3a: Seasonal delegation heatmap (month x day_of_week)
SELECT
    EXTRACT(MONTH FROM wd.created_at) AS month,
    TO_CHAR(wd.created_at, 'Mon') AS month_name,
    cww.day_of_week,
    CASE cww.day_of_week
        WHEN 0 THEN 'Sun' WHEN 1 THEN 'Mon' WHEN 2 THEN 'Tue'
        WHEN 3 THEN 'Wed' WHEN 4 THEN 'Thu' WHEN 5 THEN 'Fri'
        WHEN 6 THEN 'Sat'
    END AS day_name,
    COUNT(*) AS delegation_count,
    COUNT(DISTINCT wd.original_tenant_id) AS unique_delegators,
    COUNT(DISTINCT wd.delegate_tenant_id) AS unique_delegates
FROM walk_delegations wd
JOIN client_walk_windows cww ON cww.id = wd.walk_window_id
WHERE wd.status IN ('active', 'completed', 'accepted')
GROUP BY
    EXTRACT(MONTH FROM wd.created_at),
    TO_CHAR(wd.created_at, 'Mon'),
    cww.day_of_week
ORDER BY month, cww.day_of_week;

-- Query 3b: Time-window overflow detection
-- (When delegations cluster in specific time slots, it signals capacity overflow)
SELECT
    cww.window_start,
    cww.window_end,
    cww.day_of_week,
    wd.original_tenant_id,
    COUNT(*) AS delegation_count,
    -- Compare to total windows in that slot to compute overflow ratio
    (SELECT COUNT(*) FROM client_walk_windows cww2
     WHERE cww2.tenant_id = wd.original_tenant_id
       AND cww2.day_of_week = cww.day_of_week
       AND cww2.window_start = cww.window_start) AS total_windows_in_slot,
    ROUND(
        COUNT(*)::numeric / NULLIF(
            (SELECT COUNT(*) FROM client_walk_windows cww2
             WHERE cww2.tenant_id = wd.original_tenant_id
               AND cww2.day_of_week = cww.day_of_week
               AND cww2.window_start = cww.window_start), 0
        ) * 100, 1
    ) AS overflow_pct
FROM walk_delegations wd
JOIN client_walk_windows cww ON cww.id = wd.walk_window_id
WHERE wd.status IN ('active', 'completed', 'accepted')
GROUP BY cww.window_start, cww.window_end, cww.day_of_week, wd.original_tenant_id
HAVING COUNT(*) >= 2
ORDER BY overflow_pct DESC;

-- Query 3c: Predict upcoming overflow periods
-- Based on historical patterns, flag upcoming weeks likely to trigger delegation
WITH monthly_pattern AS (
    SELECT
        EXTRACT(MONTH FROM wd.created_at) AS pattern_month,
        cww.day_of_week,
        AVG(COUNT(*)) OVER (
            PARTITION BY EXTRACT(MONTH FROM wd.created_at), cww.day_of_week
        ) AS avg_delegations
    FROM walk_delegations wd
    JOIN client_walk_windows cww ON cww.id = wd.walk_window_id
    WHERE wd.status IN ('active', 'completed', 'accepted')
    GROUP BY EXTRACT(MONTH FROM wd.created_at), cww.day_of_week
)
SELECT
    pattern_month,
    day_of_week,
    avg_delegations,
    CASE
        WHEN avg_delegations > 5 THEN 'HIGH overflow expected'
        WHEN avg_delegations > 2 THEN 'MODERATE overflow expected'
        ELSE 'LOW overflow expected'
    END AS overflow_forecast
FROM monthly_pattern
WHERE pattern_month = EXTRACT(MONTH FROM CURRENT_DATE + INTERVAL '1 month')
ORDER BY avg_delegations DESC;
