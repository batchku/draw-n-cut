---
schema_version: 1
id: TASK-20260802-193437-ali-momeni-2
title: Auto-detect non-subject elements (enclosing circles, handwritten labels) and one-tap suggested removal
type: task
status: ready
owner: ali-momeni
status_changed_at: 2026-08-02T19:34:37Z
parent: FEAT-20260802-193436-ali-momeni
depends_on:
- TASK-20260802-193437-ali-momeni
---

# Summary

Complete Auto-detect non-subject elements (enclosing circles, handwritten labels) and one-tap suggested removal.

# Notes

- Non-subject elements are opportunistic, per-image detections — never assumptions.
  Enclosing circles and labels appear in some source drawings (see Fixtures/) and
  not others; the detector must score each traced element generically
  (subject-connected vs stray) rather than hard-code "find the big circle".
- Detection only ever *suggests*; nothing is auto-removed. The generic tap-to-delete
  removal UI (TASK-20260802-193438-ali-momeni) is the universal fallback and must not
  depend on any detector output.
