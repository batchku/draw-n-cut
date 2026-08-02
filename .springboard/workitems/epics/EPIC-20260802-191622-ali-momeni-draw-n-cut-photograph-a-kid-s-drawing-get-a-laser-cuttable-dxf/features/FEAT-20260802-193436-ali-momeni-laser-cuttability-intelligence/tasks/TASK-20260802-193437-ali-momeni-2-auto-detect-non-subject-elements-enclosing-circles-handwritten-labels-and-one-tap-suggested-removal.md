---
schema_version: 1
id: TASK-20260802-193437-ali-momeni-2
title: Auto-detect non-subject elements (enclosing circles, handwritten labels) and one-tap suggested removal
type: task
status: done
owner: ali-momeni
status_changed_at: 2026-08-02T20:09:11Z
parent: FEAT-20260802-193436-ali-momeni
depends_on:
- TASK-20260802-193437-ali-momeni
observations:
- id: observation-20260802T200910Z
  kind: operator_observed
  command: xcodebuild -project DrawNCut.xcodeproj -scheme DrawNCut -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet test
  exit_code: 0
  summary: command exited 0 in 22011 ms
  duration_ms: 22011
  cwd: .
  stdout_preview: Testing started
  stderr_preview: '2026-08-02 13:09:07.494 xcodebuild[88365:49820829] [MT] IDETestOperationsObserverDebug: 17.880 elapsed -- Testing started completed. 2026-08-02 13:09:07.494 xcodebuild[88365:49820829] [MT] IDETestOperationsObserverDebug: 0.000 sec, +0.000 sec -- start 2026-08-02 13:09:07.494 xcodebuild[88365:49820829] [MT] IDETestOperationsObserverDebug: 17.880 sec, +17.880 sec -- end'
  observed_at: 2026-08-02T20:09:10Z
  authority: operator_observed
  claim_scope: agent_volunteered_observation
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
