# Schema Validation Matrix

## Verified Schema Elements (from production database docs)

### walk_delegations FKs (CONFIRMED)

```
walk_delegations.original_tenant_id  →  tenants.id          CONFIRMED
walk_delegations.delegate_tenant_id  →  tenants.id          CONFIRMED
walk_delegations.proposed_by         →  tenants.id          CONFIRMED
walk_delegations.client_id           →  users.id            CONFIRMED
walk_delegations.walk_window_id      →  client_walk_windows.id  CONFIRMED
walk_delegations.meet_and_greet_id   →  meet_and_greets.id  CONFIRMED
```

### Related Table Structures (CONFIRMED)

```
client_walk_windows:
  id, user_id, tenant_id, day_of_week, window_start, window_end,
  effective_start, effective_end, walk_length_minutes, walk_grouping,
  created_at, updated_at
  FKs: tenant_id → tenants, user_id → users

walks:
  id, tenant_id, user_id, dog_ids, walker_id, walk_date,
  scheduled_time, walk_window_id, duration_minutes, status,
  is_confirmed, is_committed, needs_client_approval, origin_type,
  created_at, updated_at
  FKs: tenant_id → tenants, user_id → users

pending_services:
  id, user_id, tenant_id, dog_ids, service_date, service_type,
  walk_window_id, details, is_confirmed, price_preview, created_at
  FKs: user_id → users

tenants:
  id, slug, business_name, auto_seed_enabled,
  horizon_populate_frequency, horizon_populate_day,
  horizon_lead_time_days, horizon_populate_time
```

### Auto-Seed Pipeline Entry Points (CONFIRMED)

```
Worker:         workers/auto-seed-walks/index.js (Cloudflare cron)
Route:          POST /api/client-windows/seed-now
Controller:     src/clientWalkWindows/controllers/seedWalksForCurrentWeek.js
Service:        src/clientWalkWindows/services/seedWalksDirectly.js
Horizon Config: src/scheduling/services/horizonHelpers.js
```

### Enum Types (CONFIRMED)

```
walk_status:    unscheduled, scheduled, pending, in_progress,
                completed, canceled, no_show, rescheduled, banked

purchase_type:  walk, boarding, credit_pack, walk_window, daycare

user_role:      platform_admin, tenant_admin, walker, client

NOTE: NO delegation_status enum exists
```

### Code-Level Patterns (CONFIRMED)

```
Walk seeding creates:     { status: 'unscheduled', is_confirmed: false }
Client filter:            is_committed = true (hides unseeded walks)
Pending service creates:  { is_confirmed: false } (updated to true at checkout)
Worker auth:              x-worker-secret header
Idempotency:              Check before insert on (user, date, window, dogs)
```

## Unconfirmed / Inferred Elements

These columns are referenced in the experiment queries but NOT confirmed
in the production schema docs:

```
walk_delegations.status        → INFERRED (no enum, no column confirmed)
walk_delegations.created_at    → LIKELY (most tables have it, not in FK/PK data)
walk_delegations.accepted_at   → INFERRED (needed for latency, not confirmed)
walk_delegations.effective_start → INFERRED (needed for horizon alignment)
walk_delegations.effective_end   → INFERRED (needed for duration tracking)
```

## Data Sources Used

| File | Purpose |
|------|---------|
| `sniffr-backend/docs/database/foreign-keys.json` | All FK relationships |
| `sniffr-backend/docs/database/primary-key.json` | All primary keys |
| `sniffr-backend/docs/database/enum-type.json` | Enum definitions |
| `sniffr-backend/docs/database/unique-constraints.json` | Unique constraints |
| `sniffr-backend/docs/database/README.md` | Business context |
| `sniffr-backend/src/clientWalkWindows/services/seedWalksDirectly.js` | Seeding logic |
| `sniffr-backend/src/clientWalkWindows/controllers/seedWalksForCurrentWeek.js` | Seed controller |
| `sniffr-backend/src/clientWalkWindows/services/createPendingServiceForWindow.js` | Pending service flow |
| `sniffr-backend/src/walks/schemas/walksSchemas.js` | Walk schema |
| `sniffr-backend/src/walks/controllers/walksQueryController.js` | is_committed filter |
| `sniffr-backend/src/purchases/schemas/delegationSchemas.js` | Delegation stub |
| `sniffr-backend/workers/auto-seed-walks/index.js` | Auto-seed worker |
