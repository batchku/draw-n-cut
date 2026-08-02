---
schema_version: 1
type: decision
title: 'Cuttability policy: physics decides cut vs engrave, user decides content'
status: proposed
authorship_mode: agent
record_authority: proposed
rewrite_policy: agent_revisable
status_changed_at: 2026-08-02T19:35:01Z
related_workitems: []
supersedes: []
id: DEC-20260802-193501-ali-momeni
summary: Open pen strokes are never cut (engrave/score only); the only guaranteed cut is the kerf-aware offset silhouette of the SAM mask; closed inner loops may cut only when above min-hole size and provably not disconnecting material; all thresholds computed in mm at target size; non-subject elements (enclosing circles, labels) are auto-flagged for one-tap removal and any element is deletable, undoable via append-only trace versions.
---
# Context

State the problem, constraints, and assumptions that make this decision necessary.

# Decision

Describe the chosen option and the concrete commitments this decision creates.

# Consequences

Summarize expected tradeoffs, follow-on work, and what becomes invalid if this changes.

# Alternatives (Optional)

List plausible alternatives (2-4 bullets max) and why they were not chosen.

# Links (Optional)

Point to supporting artifacts so humans can audit this quickly.

- evidence: `.springboard/evidence/<run_id>.md`
- approvals: `.springboard/approvals/APR-....md`

# Notes (Optional)

Optional extra context, caveats, and follow-ups. If this decision is superseded, link to the successor and summarize what changed.
