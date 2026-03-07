# Auto-Seed Extension Architecture: Walk Seeding → Delegation Seeding

## How Walk Auto-Seeding Works Today

### The Pipeline

```
┌─────────────────────┐     ┌──────────────────────┐     ┌─────────────────┐
│  Cloudflare Worker   │────▶│  POST /seed-now       │────▶│ seedWalksDirectly│
│  (cron scheduled)    │     │  (Fastify endpoint)   │     │ (service layer)  │
│                      │     │                       │     │                  │
│  Checks:             │     │  Modes:               │     │  For each window:│
│  - auto_seed_enabled │     │  - tenant (all)       │     │  1. Get horizon  │
│  - populate_frequency│     │  - client (one user)  │     │  2. Generate dates│
│  - populate_day      │     │  - tenant_selective   │     │  3. Match DOW    │
│  - populate_time     │     │  (specific windows)   │     │  4. Check exists │
│                      │     │                       │     │  5. Insert walk  │
└─────────────────────┘     └──────────────────────┘     └─────────────────┘
```

### Key Properties

1. **Idempotent**: Checks `(user_id, walk_date, walk_window_id, dog_ids)` before insert
2. **Uncommitted**: Creates walks with `is_confirmed: false`, `status: 'unscheduled'`
3. **Invisible to clients**: `walksQueryController.js` filters `is_committed = true` for client/walker roles
4. **Horizon-based**: Uses `getHorizonConfig()` to determine date ranges
5. **Tenant-scoped**: Only processes windows belonging to the requesting tenant
6. **Worker-authenticated**: Uses `x-worker-secret` header for cron invocations

### The "Futures" Insight

```
client_walk_windows  ──[seed-now]──▶  walks (is_confirmed: false)
       │                                     │
  "right to walks"              "walks that don't exist yet"
  (contract-level)              (instance-level, uncommitted)
       │                                     │
  payment settles               admin shapes (assign walker,
  at window purchase            set time, confirm day)
```

The auto-seed pipeline creates **labor that doesn't exist yet** — shaped by admin, settled by confirmation. The walk exists in a quantum state: real enough to schedule around, not yet committed to the client.

---

## Proposed Delegation Seeding Extension

### Parallel Architecture

```
┌─────────────────────┐     ┌────────────────────────┐     ┌───────────────────────┐
│  Pattern Engine      │────▶│  POST /seed-delegations │────▶│ seedDelegationsDirectly│
│  (new worker or      │     │  (new Fastify endpoint) │     │ (new service layer)    │
│   existing worker    │     │                          │     │                        │
│   extension)         │     │  Input:                  │     │  For each pattern:     │
│                      │     │  - tenant_id             │     │  1. Score confidence   │
│  Runs:               │     │  - confidence_threshold  │     │  2. Check no existing  │
│  - After seed-now    │     │  - horizon_index         │     │  3. Insert delegation  │
│  - Same schedule     │     │                          │     │     status='suggested' │
│  - Same auth         │     │  Output:                 │     │  4. Return suggestions │
└─────────────────────┘     └────────────────────────┘     └───────────────────────┘
```

### Step-by-Step Flow

```
EXISTING PIPELINE:                        PROPOSED EXTENSION:

1. Worker fires on schedule               1. Same worker, runs after walk seeding
2. GET /tenants/auto-seed-enabled         2. Same tenant list
3. POST /seed-now (per tenant)            3. POST /seed-delegations (per tenant)
4. seedWalksDirectly():                   4. seedDelegationsDirectly():
   a. Get horizon config                     a. Get same horizon config
   b. Query client_walk_windows              b. Query walk_delegations history
   c. For each date in horizon:              c. Run pattern detection queries
      - Match day_of_week                    d. For each detected pattern:
      - Check idempotency                       - Score confidence (0.0-1.0)
      - Insert walk(is_confirmed:false)         - Check no existing delegation
                                                - Insert walk_delegation(status:'suggested')
5. Walks appear to admin only             5. Suggestions appear to tenant admin only
6. Admin assigns walker, confirms         6. Tenant reviews, promotes to 'proposed'
                                          7. Delegate tenant accepts/rejects
                                          8. Client approves (meet-and-greet gate)
```

### The Parallel Structure

| Walk Seeding | Delegation Seeding |
|-------------|-------------------|
| `client_walk_windows` (input) | `walk_delegations` history (input) |
| `walks` (output) | `walk_delegations` (output) |
| `is_confirmed: false` (uncommitted) | `status: 'suggested'` (uncommitted) |
| `status: 'unscheduled'` | `initiated_by: 'pattern_engine'` |
| Invisible to clients | Invisible to clients AND delegate tenant |
| Admin shapes → confirms | Original tenant reviews → proposes |
| Horizon-based dates | Pattern-based predictions |
| Idempotent on `(user, date, window, dogs)` | Idempotent on `(orig_tenant, del_tenant, window, horizon)` |

### Service Implementation Sketch

```javascript
// src/walkDelegations/services/seedDelegationsDirectly.js

export async function seedDelegationsDirectly(
  supabase,
  tenant_id,
  horizon_index = 0,
  options = {}
) {
  const { confidence_threshold = 0.7 } = options;

  // 1. Get horizon config (same as walk seeding)
  const horizonConfig = await getHorizonConfig({ supabase }, tenant_id, horizon_index);

  // 2. Query historical delegation patterns for this tenant
  const { data: patterns } = await supabase.rpc(
    'detect_delegation_patterns',  // DB function wrapping Query 1a
    { p_tenant_id: tenant_id, p_min_count: 2 }
  );

  // 3. For each pattern above confidence threshold
  const results = { suggested: 0, skipped_exists: 0, skipped_low_confidence: 0 };

  for (const pattern of patterns) {
    if (pattern.stability_score < confidence_threshold) {
      results.skipped_low_confidence++;
      continue;
    }

    // 4. Check if delegation already exists for this horizon
    const { data: existing } = await supabase
      .from('walk_delegations')
      .select('id')
      .eq('original_tenant_id', pattern.original_tenant_id)
      .eq('delegate_tenant_id', pattern.delegate_tenant_id)
      .eq('walk_window_id', pattern.walk_window_id)
      .gte('effective_start', horizonConfig.current_horizon_start)
      .lte('effective_start', horizonConfig.current_horizon_end)
      .maybeSingle();

    if (existing) {
      results.skipped_exists++;
      continue;
    }

    // 5. Seed the suggestion
    const { error } = await supabase
      .from('walk_delegations')
      .insert({
        original_tenant_id: tenant_id,
        delegate_tenant_id: pattern.delegate_tenant_id,
        walk_window_id: pattern.walk_window_id,
        client_id: pattern.client_id,
        proposed_by: null,           // System-initiated
        initiated_by: 'pattern_engine',
        status: 'suggested',
        effective_start: horizonConfig.current_horizon_start,
        effective_end: horizonConfig.current_horizon_end,
        created_at: new Date().toISOString(),
        confidence_score: pattern.stability_score  // Optional metadata
      });

    if (!error) results.suggested++;
  }

  return results;
}
```

### Worker Extension

```javascript
// In workers/auto-seed-walks/index.js, after walk seeding:

// Existing: seed walks
await fetch(`${API_BASE}/api/client-windows/seed-now`, {
  method: 'POST',
  headers: { 'x-worker-secret': env.WORKER_SECRET },
  body: JSON.stringify({ mode: 'tenant', tenant_id, weeks_ahead })
});

// NEW: seed delegation suggestions (same worker, same schedule)
if (tenant.delegation_seeding_enabled) {
  await fetch(`${API_BASE}/api/walk-delegations/seed-suggestions`, {
    method: 'POST',
    headers: { 'x-worker-secret': env.WORKER_SECRET },
    body: JSON.stringify({
      tenant_id,
      confidence_threshold: tenant.delegation_confidence_threshold || 0.7,
      weeks_ahead
    })
  });
}
```

### Tenant Configuration Extension

```sql
-- Add to tenants table (parallels auto_seed_enabled)
ALTER TABLE tenants
    ADD COLUMN delegation_seeding_enabled BOOLEAN DEFAULT FALSE,
    ADD COLUMN delegation_confidence_threshold NUMERIC(3,2) DEFAULT 0.70;
```

---

## Three-Party Approval Flow (Preserved)

```
SYSTEM detects pattern
    │
    ▼
walk_delegation(status='suggested', initiated_by='pattern_engine')
    │
    ▼ Original tenant admin reviews suggestion
    │
walk_delegation(status='proposed', proposed_by=original_tenant_id)
    │
    ▼ Delegate tenant receives proposal
    │
walk_delegation(status='accepted', accepted_at=NOW())
    │
    ▼ [IF meet_and_greet required]
    │
walk_delegation(status='pending_greet', meet_and_greet_id=...)
    │
    ▼ Client approves
    │
walk_delegation(status='active', client_approved=true)
    │
    ▼ Walk seeding picks up active delegations
    │
walks seeded under delegate_tenant_id for the delegated window
```

**The three-party approval flow remains intact.** The only change is who initiates: `tenant` → `pattern_engine`. The `suggested` status is the new pre-proposal state that preserves human agency while enabling system intelligence.

---

## What This Architecture Does NOT Do

1. **Does NOT bypass tenant consent** — suggestions require explicit promotion to proposals
2. **Does NOT create walks** — only creates delegation records in `suggested` status
3. **Does NOT notify the delegate tenant** — only the original tenant sees suggestions
4. **Does NOT require historical data** — degrades gracefully to zero suggestions with zero history
5. **Does NOT create a "market"** — no pricing, no bidding, no competition between delegates
