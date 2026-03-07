# Predictive Delegation Seeding: Can Sniffr's Auto-Seed Pipeline Generate Cross-Tenant Coverage Offers?

## Hypothesis

Sniffr's auto-seed pipeline (`seed-now` → `walks(is_confirmed: false)`) can be architecturally extended to seed delegation suggestions (`detected pattern` → `walk_delegation(status: 'suggested')`), and the existing `walk_delegations` schema has the FK structure to support labor topology discovery — with specific, documented, additive gaps.

**Prediction:** The schema is 70% ready and the pipeline is 90% extensible. The main gaps will be operational columns (status, timestamps), not structural FK redesign.

## Setup

**Systems researched via Agent Teams:**
- `sniffr-backend/docs/database/` — Production schema docs (foreign-keys.json, primary-key.json, enum-type.json, unique-constraints.json, README.md)
- `sniffr-backend/src/clientWalkWindows/` — Auto-seed pipeline (seedWalksDirectly.js, createPendingServiceForWindow.js, routes.js, controllers/)
- `sniffr-backend/src/walks/` — Walk schemas, is_committed filter, scheduling service
- `sniffr-backend/src/purchases/schemas/` — Delegation schema stub (delegationSchemas.js)
- `sniffr-backend/workers/auto-seed-walks/` — Cloudflare cron worker
- `sniffr-backend/src/scheduling/` — Horizon config and scheduling schemas

## Approach

### Step 1: Model Three Delegation Archetypes Against Actual Schema

Wrote SQL detection queries for each pattern using verified FK relationships from `walk_delegations`:

1. **Regular Coverage** — Stable `(original_tenant, delegate_tenant, walk_window)` tuples recurring over time. Computed stability scores with exponential recency decay. Includes predictive gap detection: "windows that SHOULD be delegated but haven't been yet."

2. **Emergency Handoff** — Short-notice delegations (<48h) detected by comparing `walk_delegations.created_at` against next `walks.walk_date` via `walk_window_id` JOIN. Identified that instance-level handoffs need a `walk_id` FK not present in current schema.

3. **Seasonal Overflow** — Delegation density by month × day_of_week heatmap, plus time-window capacity overflow detection comparing delegations-per-slot to total windows-per-slot.

**Deliverable:** `delegation-pattern-detection.sql` (8 queries, ~200 lines)

### Step 2: Identify Schema Gaps

Analyzed every column and FK on `walk_delegations` against what predictive seeding requires:

| Gap | Severity | Notes |
|-----|----------|-------|
| `proposed_by` → `tenants.id` blocks system proposals | HIGH | FK requires tenant UUID; system has none |
| No `status` column or `delegation_status` enum | HIGH | Can't distinguish suggestions from proposals |
| No temporal columns (`created_at`, `accepted_at`) | HIGH | Can't measure patterns or latency |
| No `walk_id` FK for instance-level delegation | MEDIUM | Only blocks emergency handoff archetype |
| No `client_approved` tracking | MEDIUM | Downstream, doesn't block seeding |

All gaps are **additive migrations** — zero FK redesign needed.

**Key finding:** The `delegationSchemas.js` file is a stub with only `{ id }`, confirming delegation CRUD hasn't been built yet. The database FKs are ahead of the application layer.

**Deliverable:** `schema-gap-analysis.md`

### Step 3: Map Auto-Seed Extension

Documented the existing pipeline flow:

```
Cloudflare Worker → POST /seed-now → seedWalksDirectly() → walks(is_confirmed: false)
```

Then sketched the parallel delegation flow:

```
Same Worker → POST /seed-delegations → seedDelegationsDirectly() → walk_delegations(status: 'suggested')
```

The parallel is structural:
- Walk seeding transforms `client_walk_windows` (contracts) into `walks` (instances)
- Delegation seeding transforms `walk_delegations` history (patterns) into `walk_delegations` suggestions (predictions)
- Both use `getHorizonConfig()` for date ranges
- Both are idempotent, uncommitted, and invisible to clients
- Both are toggled per-tenant (`auto_seed_enabled` / `delegation_seeding_enabled`)

Included service implementation sketch (~50 lines JS) and worker extension (~5 lines).

**Deliverable:** `auto-seed-extension-architecture.md`

### Step 4: Topology Graph Query

Wrote a composite SQL query computing:
- **Directed edges** between tenants (delegator → delegate)
- **Edge strength** (composite of frequency, recency, acceptance rate, diversity)
- **Edge type classification** (strategic partner, regular coverage, mutual aid, rapid responder)
- **Node metrics** (in-degree, out-degree, network role)
- **Cluster detection** (bidirectional tenant pairs with reciprocity ratio)

Validated FK structure: 7/10 topology metrics are computable with zero schema changes. The 3 requiring changes all need the same temporal columns identified in Gap Analysis.

**Deliverable:** `tenant-topology-query.sql`

## Results

### Feasibility Score: 7.6/10

| Dimension | Score | Reasoning |
|-----------|-------|-----------|
| Schema readiness | 7/10 | FKs correct; 5 additive gaps |
| Pipeline extensibility | 9/10 | Direct parallel to existing architecture |
| Query expressibility | 8/10 | All archetypes expressible with noted gaps |
| Product fit | 6/10 | Needs >2 tenants with history to predict |
| Implementation effort | 8/10 | ~3 migrations + 1 service + worker extension |

### Key Findings

1. **The FK structure is right.** `walk_delegations.walk_window_id` → `client_walk_windows.id` is the correct granularity for contract-level delegation patterns. Window-level is more predictable than instance-level.

2. **The pipeline is directly extensible.** `seedDelegationsDirectly()` follows the exact same pattern as `seedWalksDirectly()`: get horizon → query input → check idempotency → insert uncommitted. The worker extension is literally one extra `fetch()` call.

3. **The biggest gap is conceptual, not technical.** Making `proposed_by` nullable (or adding `initiated_by`) requires a product decision: is "the system" a proposer in the same sense a tenant is? This is a 1-line migration but a non-trivial product question.

4. **The Critic is right about data.** Zero delegation records = zero predictions. But the Explorer is also right: knowing the queries work *before* building delegation means the operational columns get included from the start, not bolted on later.

5. **The "futures market" interpretation is premature.** The delegation seeding extension is valuable as a UX optimization (suggest before asking). The "labor topology" framing is interesting but needs network effects that a 2-3 tenant system can't generate.

### Surprises

- The `delegationSchemas.js` is a **stub** — delegation CRUD isn't built at the app layer, only the DB schema exists. This means the migration window is wide open.
- The `is_committed` / `is_confirmed` dual-boolean pattern on walks is more nuanced than expected — `is_committed` controls client visibility, `is_confirmed` controls settlement. A `status` enum on delegations is cleaner than replicating this.
- The auto-seed worker already supports `tenant_selective` mode with `window_ids` filter — the delegation seeder can reuse this architecture directly.

## Verdict

**Worth pursuing** — but as a schema-first, data-second approach. The recommended action:

1. Add the 5 operational columns to `walk_delegations` BEFORE building delegation CRUD (the migration window is open since the app layer is a stub)
2. Build delegation CRUD with the `suggested` status included from day one
3. Add the pattern detection queries as a DB function (`detect_delegation_patterns`)
4. Wire up the seeding extension AFTER delegation has generated enough data (>20 records per tenant pair)

This is a "plant the seed now, harvest later" finding — the architecture supports it, but the value appears only after delegation is live and generating patterns.

## Next Steps

1. **Immediate:** Include the 5 gap columns in the delegation migration PR that's being planned
2. **When delegation ships:** Add the `detect_delegation_patterns` DB function
3. **After 2-3 months of delegation data:** Wire up `seedDelegationsDirectly()` and enable per-tenant
4. **Never (probably):** The "labor futures market" framing — it's a compelling metaphor but not a product feature at current scale

## Deliverables

| File | Description |
|------|-------------|
| `delegation-pattern-detection.sql` | 8 SQL queries for 3 delegation archetypes |
| `schema-gap-analysis.md` | 5 identified gaps with migration proposals |
| `auto-seed-extension-architecture.md` | Pipeline extension design with code sketches |
| `tenant-topology-query.sql` | Graph query with edge strength, node metrics, cluster detection |
| `results/feasibility-assessment.md` | Detailed test results and scoring |
| `results/schema-validation-matrix.md` | Every verified vs inferred schema element |
