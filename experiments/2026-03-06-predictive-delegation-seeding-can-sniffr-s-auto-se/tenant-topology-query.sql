-- =============================================================================
-- TENANT-TO-TENANT LABOR TOPOLOGY GRAPH QUERY
-- Predictive Delegation Seeding Experiment
-- =============================================================================
-- Computes directed edges between tenants based on delegation relationships.
-- Each edge represents a delegator→delegate relationship with:
--   - Directionality (who delegates to whom)
--   - Frequency (how often)
--   - Acceptance latency (how quickly delegates respond)
--   - Recency (when was the last interaction)
--
-- This tests whether the existing FK structure supports labor topology discovery.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- CORE GRAPH QUERY: Directed Delegation Edges
-- ─────────────────────────────────────────────────────────────────────────────

WITH delegation_edges AS (
    SELECT
        wd.original_tenant_id AS source_tenant_id,
        wd.delegate_tenant_id AS target_tenant_id,

        -- Frequency metrics
        COUNT(*) AS total_delegations,
        COUNT(*) FILTER (WHERE wd.status IN ('active', 'completed')) AS successful_delegations,
        COUNT(*) FILTER (WHERE wd.status = 'rejected') AS rejected_delegations,

        -- Temporal metrics
        MIN(wd.created_at) AS first_delegation,
        MAX(wd.created_at) AS latest_delegation,
        EXTRACT(EPOCH FROM (MAX(wd.created_at) - MIN(wd.created_at))) / 86400
            AS relationship_duration_days,

        -- Acceptance latency (how fast does the delegate respond?)
        AVG(EXTRACT(EPOCH FROM (wd.accepted_at - wd.created_at))) / 3600
            AS avg_acceptance_hours,
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY EXTRACT(EPOCH FROM (wd.accepted_at - wd.created_at))
        ) / 3600 AS median_acceptance_hours,

        -- Window diversity (how many different windows are delegated?)
        COUNT(DISTINCT wd.walk_window_id) AS unique_windows_delegated,

        -- Client diversity (how many different clients are involved?)
        COUNT(DISTINCT wd.client_id) AS unique_clients_affected,

        -- Day-of-week distribution
        ARRAY_AGG(DISTINCT cww.day_of_week ORDER BY cww.day_of_week) AS delegated_days,

        -- Meet-and-greet gate usage
        COUNT(*) FILTER (WHERE wd.meet_and_greet_id IS NOT NULL) AS greet_required_count,

        -- Reciprocity check: does the target ever delegate back?
        EXISTS (
            SELECT 1 FROM walk_delegations wd2
            WHERE wd2.original_tenant_id = wd.delegate_tenant_id
              AND wd2.delegate_tenant_id = wd.original_tenant_id
        ) AS is_reciprocal

    FROM walk_delegations wd
    JOIN client_walk_windows cww ON cww.id = wd.walk_window_id
    WHERE wd.status NOT IN ('expired', 'cancelled')  -- Exclude noise
    GROUP BY wd.original_tenant_id, wd.delegate_tenant_id
),

-- ─────────────────────────────────────────────────────────────────────────────
-- ENRICHMENT: Add tenant names and compute edge strength
-- ─────────────────────────────────────────────────────────────────────────────

enriched_edges AS (
    SELECT
        de.*,
        t_src.slug AS source_slug,
        t_src.business_name AS source_name,
        t_tgt.slug AS target_slug,
        t_tgt.business_name AS target_name,

        -- Edge strength: composite score (0-1)
        -- Weighted combination of frequency, recency, and reliability
        LEAST(1.0,
            (0.4 * LEAST(de.successful_delegations::numeric / 10, 1.0))  -- Frequency (capped at 10)
            + (0.3 * EXP(-EXTRACT(EPOCH FROM (NOW() - de.latest_delegation)) / (90 * 86400)))  -- Recency (90-day decay)
            + (0.2 * (1.0 - COALESCE(de.rejected_delegations::numeric / NULLIF(de.total_delegations, 0), 0)))  -- Acceptance rate
            + (0.1 * LEAST(de.unique_windows_delegated::numeric / 5, 1.0))  -- Diversity (capped at 5)
        ) AS edge_strength,

        -- Edge type classification
        CASE
            WHEN de.successful_delegations >= 10 AND de.unique_windows_delegated >= 3
                THEN 'STRATEGIC_PARTNER'      -- Deep, multi-window relationship
            WHEN de.successful_delegations >= 5
                THEN 'REGULAR_COVERAGE'       -- Established pattern
            WHEN de.is_reciprocal
                THEN 'MUTUAL_AID'             -- Bidirectional relationship
            WHEN de.avg_acceptance_hours < 4
                THEN 'RAPID_RESPONDER'        -- Emergency-capable partner
            ELSE 'OCCASIONAL'                 -- Infrequent
        END AS edge_type

    FROM delegation_edges de
    JOIN tenants t_src ON t_src.id = de.source_tenant_id
    JOIN tenants t_tgt ON t_tgt.id = de.target_tenant_id
)

-- ─────────────────────────────────────────────────────────────────────────────
-- FINAL OUTPUT: Complete topology graph
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
    source_slug,
    '→' AS direction,
    target_slug,
    edge_type,
    ROUND(edge_strength::numeric, 3) AS edge_strength,
    total_delegations,
    successful_delegations,
    unique_windows_delegated,
    unique_clients_affected,
    delegated_days,
    ROUND(avg_acceptance_hours::numeric, 1) AS avg_accept_hrs,
    ROUND(median_acceptance_hours::numeric, 1) AS median_accept_hrs,
    is_reciprocal,
    relationship_duration_days,
    latest_delegation
FROM enriched_edges
ORDER BY edge_strength DESC;


-- =============================================================================
-- SUPPLEMENTARY: Network-Level Metrics
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- TENANT NODE METRICS: Degree centrality for each tenant
-- ─────────────────────────────────────────────────────────────────────────────

-- How connected is each tenant in the delegation network?
WITH node_metrics AS (
    SELECT
        t.id AS tenant_id,
        t.slug,
        -- Out-degree: how many tenants does this tenant delegate TO?
        (SELECT COUNT(DISTINCT delegate_tenant_id)
         FROM walk_delegations
         WHERE original_tenant_id = t.id
           AND status IN ('active', 'completed', 'accepted')
        ) AS out_degree,
        -- In-degree: how many tenants delegate TO this tenant?
        (SELECT COUNT(DISTINCT original_tenant_id)
         FROM walk_delegations
         WHERE delegate_tenant_id = t.id
           AND status IN ('active', 'completed', 'accepted')
        ) AS in_degree,
        -- Total delegations originated
        (SELECT COUNT(*)
         FROM walk_delegations
         WHERE original_tenant_id = t.id
           AND status IN ('active', 'completed', 'accepted')
        ) AS delegations_out,
        -- Total delegations received
        (SELECT COUNT(*)
         FROM walk_delegations
         WHERE delegate_tenant_id = t.id
           AND status IN ('active', 'completed', 'accepted')
        ) AS delegations_in
    FROM tenants t
)
SELECT
    slug,
    out_degree,
    in_degree,
    out_degree + in_degree AS total_degree,
    delegations_out,
    delegations_in,
    CASE
        WHEN in_degree > out_degree * 2 THEN 'NET_PROVIDER'   -- Mostly receives work
        WHEN out_degree > in_degree * 2 THEN 'NET_DELEGATOR'  -- Mostly sends work
        WHEN out_degree > 0 AND in_degree > 0 THEN 'BILATERAL' -- Both directions
        WHEN out_degree = 0 AND in_degree = 0 THEN 'ISOLATED'  -- No delegation activity
        ELSE 'ASYMMETRIC'
    END AS network_role
FROM node_metrics
WHERE delegations_out > 0 OR delegations_in > 0
ORDER BY total_degree DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- CLUSTER DETECTION: Find mutual aid groups
-- ─────────────────────────────────────────────────────────────────────────────

-- Identify tenant clusters where delegation is bidirectional
-- (These are the "Packs" emerging from labor patterns)
WITH bidirectional_pairs AS (
    SELECT
        LEAST(wd1.original_tenant_id, wd1.delegate_tenant_id) AS tenant_a,
        GREATEST(wd1.original_tenant_id, wd1.delegate_tenant_id) AS tenant_b,
        COUNT(*) FILTER (WHERE wd1.original_tenant_id < wd1.delegate_tenant_id) AS a_to_b_count,
        COUNT(*) FILTER (WHERE wd1.original_tenant_id > wd1.delegate_tenant_id) AS b_to_a_count
    FROM walk_delegations wd1
    WHERE EXISTS (
        -- Reverse edge exists
        SELECT 1 FROM walk_delegations wd2
        WHERE wd2.original_tenant_id = wd1.delegate_tenant_id
          AND wd2.delegate_tenant_id = wd1.original_tenant_id
          AND wd2.status IN ('active', 'completed', 'accepted')
    )
    AND wd1.status IN ('active', 'completed', 'accepted')
    GROUP BY
        LEAST(wd1.original_tenant_id, wd1.delegate_tenant_id),
        GREATEST(wd1.original_tenant_id, wd1.delegate_tenant_id)
)
SELECT
    t_a.slug AS tenant_a_slug,
    t_b.slug AS tenant_b_slug,
    bp.a_to_b_count,
    bp.b_to_a_count,
    bp.a_to_b_count + bp.b_to_a_count AS total_interactions,
    ROUND(
        LEAST(bp.a_to_b_count, bp.b_to_a_count)::numeric /
        NULLIF(GREATEST(bp.a_to_b_count, bp.b_to_a_count), 0), 2
    ) AS reciprocity_ratio  -- 1.0 = perfectly balanced, 0.0 = one-directional
FROM bidirectional_pairs bp
JOIN tenants t_a ON t_a.id = bp.tenant_a
JOIN tenants t_b ON t_b.id = bp.tenant_b
ORDER BY total_interactions DESC;


-- =============================================================================
-- FK STRUCTURE VALIDATION
-- =============================================================================
-- This query validates that the existing FK structure is sufficient for
-- topology discovery WITHOUT schema changes.
--
-- RESULT: YES — the existing FKs on walk_delegations support:
--   ✓ Directed edges (original_tenant_id → delegate_tenant_id)
--   ✓ Edge frequency (COUNT grouping on tenant pairs)
--   ✓ Window-level pattern detection (walk_window_id → client_walk_windows)
--   ✓ Client impact analysis (client_id → users)
--   ✓ Day-of-week decomposition (via walk_window_id JOIN)
--   ✓ Meet-and-greet gate tracking (meet_and_greet_id)
--   ✓ Proposal attribution (proposed_by → tenants)
--
-- MISSING for full topology:
--   ✗ Acceptance latency (needs accepted_at timestamp)
--   ✗ Status lifecycle (needs status column)
--   ✗ Temporal analysis (needs created_at timestamp)
--   ✗ Instance-level edges (needs walk_id FK for emergency handoffs)
--
-- The FK structure is SUFFICIENT for topology shape.
-- The operational columns are needed for topology DYNAMICS.
-- =============================================================================
