# Schema Gap Analysis: Predictive Delegation Seeding

## Current `walk_delegations` Schema (Verified from Production)

**Source:** `/sniffr-backend/docs/database/foreign-keys.json`, `primary-key.json`

| Column | Type | FK Target | Constraint |
|--------|------|-----------|------------|
| `id` | uuid | PK | `walk_delegations_pkey` |
| `original_tenant_id` | uuid | `tenants.id` | `walk_delegations_original_tenant_id_fkey` |
| `delegate_tenant_id` | uuid | `tenants.id` | `walk_delegations_delegate_tenant_id_fkey` |
| `proposed_by` | uuid | `tenants.id` | `walk_delegations_proposed_by_fkey` |
| `client_id` | uuid | `users.id` | `walk_delegations_client_id_fkey` |
| `walk_window_id` | uuid | `client_walk_windows.id` | `walk_delegations_walk_window_id_fkey` |
| `meet_and_greet_id` | uuid | `meet_and_greets.id` | `walk_delegations_meet_and_greet_id_fkey` |

**Notable:** No delegation-specific enum type exists in `enum-type.json`. No `delegation_status` enum.
**Notable:** The `delegationSchemas.js` in the codebase is a **stub** with only `{ id }` defined.

---

## Gap 1: `proposed_by` → `tenants.id` Blocks System-Initiated Suggestions

### The Problem

`proposed_by` has an FK constraint to `tenants.id`. System-initiated delegation suggestions don't come from a tenant — they come from the **system**. There's no `tenants` row for "the system."

### Options

| Approach | Pros | Cons |
|----------|------|------|
| **A. Add `proposed_by_type` column** | Clean semantic separation. `proposed_by_type = 'system' \| 'tenant'`. When `system`, `proposed_by` is null. | Extra column, nullable FK. |
| **B. Create a sentinel "system" tenant** | Zero schema changes. Insert a tenant with known UUID like `00000000-0000-0000-0000-000000000000`. | Pollutes tenant table. Breaks assumptions about tenants being real businesses. |
| **C. Make `proposed_by` nullable** | Minimal change. Null = system-proposed. | Loses attribution. Less explicit than Option A. |
| **D. Add `initiated_by` enum column** | Separate the "who initiated" from "which tenant proposed." `initiated_by = 'tenant' \| 'system' \| 'pattern_engine'`. Keep `proposed_by` for the tenant that would benefit. | Most flexible but most changes. |

### Recommendation: **Option D** (with Option C as minimum viable)

Option D maps cleanly to the auto-seed architecture. The auto-seed worker already has a distinct identity (`x-worker-secret` auth header). Adding `initiated_by` parallels how `origin_type` works on `walks` (`'walk_window'`, `'walk_request'`, `'direct'`).

**Minimum viable migration:**
```sql
-- Option C: minimal
ALTER TABLE walk_delegations
    ALTER COLUMN proposed_by DROP NOT NULL;
-- NULL proposed_by = system-initiated

-- Option D: recommended
ALTER TABLE walk_delegations
    ADD COLUMN initiated_by TEXT DEFAULT 'tenant'
    CHECK (initiated_by IN ('tenant', 'system', 'pattern_engine'));
```

---

## Gap 2: Missing `status` Column

### The Problem

The `walk_delegations` table has no `status` column and no `delegation_status` enum. The debate context references a `suggested` status for predictive seeding, but there's no status lifecycle at all.

### Required Status Lifecycle

```
suggested → proposed → accepted → active → completed
                    ↘ rejected
                    ↘ expired
```

For predictive seeding, the critical addition is `suggested` — a pre-proposal state where the system has identified a likely delegation but no tenant has acted yet.

### Proposed Migration

```sql
-- Create the delegation status enum
CREATE TYPE delegation_status AS ENUM (
    'suggested',      -- System-predicted, no tenant action yet
    'proposed',       -- A tenant (or system) has formally proposed
    'pending_greet',  -- Awaiting meet-and-greet completion
    'accepted',       -- Delegate tenant accepted
    'active',         -- Client approved, delegation is live
    'completed',      -- Delegation period ended normally
    'rejected',       -- Delegate tenant declined
    'expired',        -- Suggestion/proposal timed out
    'cancelled'       -- Withdrawn by original tenant
);

ALTER TABLE walk_delegations
    ADD COLUMN status delegation_status DEFAULT 'proposed';
```

---

## Gap 3: Missing Temporal Columns

### The Problem

No `created_at`, `accepted_at`, `effective_start`, or `effective_end` columns are confirmed in the FK/PK/index data. These are essential for:
- Pattern detection queries (when was delegation created?)
- Acceptance latency measurement (how fast do delegates respond?)
- Seasonal analysis (when do delegations cluster?)

### Proposed Migration

```sql
ALTER TABLE walk_delegations
    ADD COLUMN created_at TIMESTAMPTZ DEFAULT NOW(),
    ADD COLUMN updated_at TIMESTAMPTZ,
    ADD COLUMN accepted_at TIMESTAMPTZ,
    ADD COLUMN effective_start DATE,
    ADD COLUMN effective_end DATE,
    ADD COLUMN expired_at TIMESTAMPTZ;
```

---

## Gap 4: Missing `walk_id` FK for Instance-Level Emergency Handoffs

### The Problem

`walk_delegations.walk_window_id` FK links to `client_walk_windows.id` — this supports **contract-level** delegation (e.g., "delegate all Thursday afternoon walks to Tenant B"). But emergency handoffs operate at the **instance level**: "I can't do *this specific walk* tomorrow, can you cover?"

The current schema can't express: "delegate walk #abc123 on March 7th" without also delegating the entire recurring window.

### Analysis

| Level | FK | Use Case | Supported? |
|-------|-----|----------|-----------|
| Contract (recurring) | `walk_window_id` | "Cover my Thursdays" | YES |
| Instance (one-off) | `walk_id` (missing) | "Cover tomorrow's walk" | NO |

### Proposed Migration

```sql
ALTER TABLE walk_delegations
    ADD COLUMN walk_id UUID REFERENCES walks(id);

-- Allow either window-level or walk-level delegation, but not both
ALTER TABLE walk_delegations
    ADD CONSTRAINT delegation_level_check
    CHECK (
        (walk_window_id IS NOT NULL AND walk_id IS NULL)
        OR (walk_window_id IS NULL AND walk_id IS NOT NULL)
    );
```

### Impact on Predictive Seeding

Instance-level (`walk_id`) delegations are inherently **less predictable** than window-level ones. The pattern detection queries should weight window-level delegations higher for prediction confidence.

---

## Gap 5: Missing Client Approval Column

### The Problem

The debate context describes a three-party approval flow: original tenant proposes, delegate accepts, **client approves**. There's a `client_id` FK but no column tracking whether the client has approved the delegation.

### Proposed Migration

```sql
ALTER TABLE walk_delegations
    ADD COLUMN client_approved BOOLEAN DEFAULT FALSE,
    ADD COLUMN client_approved_at TIMESTAMPTZ;
```

This mirrors the `is_confirmed` / `is_committed` pattern used in walks.

---

## Gap Summary

| Gap | Severity | Blocks Predictive Seeding? | Migration Complexity |
|-----|----------|---------------------------|---------------------|
| `proposed_by` blocks system initiation | HIGH | YES — can't create system suggestions | LOW (1 column) |
| Missing `status` column/enum | HIGH | YES — can't distinguish suggestions from proposals | MEDIUM (new enum + column) |
| Missing temporal columns | HIGH | YES — can't measure patterns or latency | LOW (4 columns) |
| Missing `walk_id` FK | MEDIUM | Partially — only blocks emergency handoff detection | LOW (1 column + constraint) |
| Missing client approval tracking | MEDIUM | No — approval is a downstream concern | LOW (2 columns) |

### Verdict

The schema **structure** (FKs, relationships) is sound. The gaps are all **operational columns** — status lifecycle, timestamps, system initiation support. These are additive migrations, not structural redesigns. The architectural bet that delegation operates at window-level is validated by the FK to `client_walk_windows.id`.

**The hardest gap is conceptual, not technical:** adding `initiated_by` or making `proposed_by` nullable requires deciding whether the system is a "proposer" in the same sense a tenant is. This is a product question, not a schema question.
