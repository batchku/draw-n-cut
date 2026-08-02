---
schema_version: 1
id: TASK-20260802-191622-ali-momeni-5
title: 'Lighting normalization: shadow removal and adaptive binarization of the rectified drawing'
type: task
status: in_progress
owner: ali-momeni
status_changed_at: 2026-08-02T21:21:35Z
parent: FEAT-20260802-191622-ali-momeni-2
depends_on:
- TASK-20260802-191622-ali-momeni-4
authoring_shape: work_tree
observations:
- id: observation-20260802T220647Z
  kind: operator_observed
  command: xcodebuild -project DrawNCut.xcodeproj -scheme DrawNCut -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet test
  exit_code: 0
  summary: command exited 0 in 5203 ms
  duration_ms: 5203
  cwd: .
  stdout_preview: Testing started
  stderr_preview: '2026-08-02 15:06:47.038 xcodebuild[17172:50127506] [MT] IDETestOperationsObserverDebug: 3.093 elapsed -- Testing started completed. 2026-08-02 15:06:47.038 xcodebuild[17172:50127506] [MT] IDETestOperationsObserverDebug: 0.000 sec, +0.000 sec -- start 2026-08-02 15:06:47.038 xcodebuild[17172:50127506] [MT] IDETestOperationsObserverDebug: 3.093 sec, +3.093 sec -- end'
  observed_at: 2026-08-02T22:06:47Z
  authority: operator_observed
  claim_scope: agent_volunteered_observation
- id: observation-20260802T220700Z
  kind: operator_observed
  command: xcodebuild -project DrawNCut.xcodeproj -scheme DrawNCut -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet test
  exit_code: 0
  summary: command exited 0 in 4251 ms
  duration_ms: 4251
  cwd: .
  stdout_preview: Testing started
  stderr_preview: '2026-08-02 15:07:00.128 xcodebuild[17852:50129661] [MT] IDETestOperationsObserverDebug: 2.964 elapsed -- Testing started completed. 2026-08-02 15:07:00.128 xcodebuild[17852:50129661] [MT] IDETestOperationsObserverDebug: 0.000 sec, +0.000 sec -- start 2026-08-02 15:07:00.128 xcodebuild[17852:50129661] [MT] IDETestOperationsObserverDebug: 2.964 sec, +2.964 sec -- end'
  observed_at: 2026-08-02T22:07:00Z
  authority: operator_observed
  claim_scope: agent_volunteered_observation
- id: observation-20260802T220724Z
  kind: operator_observed
  command: xcodebuild -project DrawNCut.xcodeproj -scheme DrawNCut -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet test
  exit_code: 0
  summary: command exited 0 in 4436 ms
  duration_ms: 4436
  cwd: .
  stdout_preview: Testing started
  stderr_preview: '2026-08-02 15:07:24.431 xcodebuild[18495:50131640] [MT] IDETestOperationsObserverDebug: 3.048 elapsed -- Testing started completed. 2026-08-02 15:07:24.431 xcodebuild[18495:50131640] [MT] IDETestOperationsObserverDebug: 0.000 sec, +0.000 sec -- start 2026-08-02 15:07:24.431 xcodebuild[18495:50131640] [MT] IDETestOperationsObserverDebug: 3.048 sec, +3.048 sec -- end'
  observed_at: 2026-08-02T22:07:24Z
  authority: operator_observed
  claim_scope: agent_volunteered_observation
---

# Summary

Complete Lighting normalization: shadow removal and adaptive binarization of the rectified drawing.
