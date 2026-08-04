# SAM 2 Segmentation — Integration Notes

On-device subject selection via Apple's official Core ML port of SAM 2.1
(`apple/coreml-sam2.1-small` on Hugging Face, Apache-2.0). The mask boundary
becomes the sticker-style CUT outline; inner strokes engrave.

## Models

Run `scripts/download-models.sh` (idempotent, sha256-verified) to populate
`Models/` at the repo root (git-ignored via `Models/.gitignore`):

| Model | Package | Size |
|---|---|---|
| Image encoder | `SAM2_1SmallImageEncoderFLOAT16.mlpackage` | 81.5 MB |
| Prompt encoder | `SAM2_1SmallPromptEncoderFLOAT16.mlpackage` | 2.1 MB |
| Mask decoder | `SAM2_1SmallMaskDecoderFLOAT16.mlpackage` | 10.3 MB |
| **Total** | | **~94 MB** |

Why Small over Tiny (~79 MB): the boundary quality directly drives the laser
cut path; the extra ~15 MB is cheap for the better hiera-small backbone. The
wrapper is variant-agnostic — drop the Tiny packages into the same directory
and it will pick them up (it matches on `ImageEncoder`/`PromptEncoder`/
`MaskDecoder` in the filename, `.mlmodelc` preferred over `.mlpackage`).

## API handshake

```swift
let segmenter = try await SAM2Segmenter(
    modelsDirectory: modelsURL,        // dir containing the 3 packages
    computeUnits: .all)                // .all on device (ANE); .cpuAndGPU on Mac dev boxes

try await segmenter.encode(image: cgImage)      // once per photo (caches embeddings)

let mask: SegmentationMask = try await segmenter.mask(points: [
    (SIMD2(x, y), true),               // tap on subject  (original image px coords)
    (SIMD2(bx, by), false),            // optional: tap on background to exclude
])
// mask.width/height == cgImage.width/height
// mask.pixels[y * width + x] == true  → inside subject → bridge to BinaryBitmap
```

- `SAM2Segmenter` is an actor; embeddings are cached until `reset()` or the
  next `encode`. After one encode, each new tap is a ~15–60 ms decode, so
  interactive refinement is cheap.
- 1 to 14 points per prompt: the mask decoder's enumerated sparse-embedding
  shapes stop at 15 rows (points + 1 padding token), so 15-16 points fail with
  "not in enumerated set of allowed shapes" (verified by sweep). Labels:
  `true` = foreground, `false` = background.
- Box prompts ARE supported by the models (SAM convention: two extra points
  labeled 2 = top-left, 3 = bottom-right). The current API only exposes point
  prompts; extend `mask(points:)` with an `Int` label variant if the UI grows
  a box tool — verified working against these models in the test harness.
- Best of SAM's 3 candidate masks is chosen by predicted-IoU score; logits are
  bilinearly upsampled to original resolution and thresholded at 0.
- Coordinates: origin top-left, x right, y down (CGImage pixel space). The
  image is scale-filled (squashed, not letterboxed) to 1024x1024 — the wrapper
  handles the coordinate transform, callers always use original-image pixels.
- IMPORTANT: `encode` takes a `CGImage` and ignores EXIF orientation. If the
  photo comes from `UIImage`/camera, render it upright first (e.g. draw into a
  context using `UIImage.draw`) before passing `cgImage`, and keep prompt
  coordinates in that same upright space.

## Measured latency (this Mac, `.cpuAndGPU`, CLI harness)

| Phase | Cold (first-ever run: mlpackage compile + GPU kernel specialization) | Warm (cached `.mlmodelc` + OS model cache) |
|---|---|---|
| Model load (all 3) | ~0.5 s + compile | 0.16 s |
| `encode` (1950x2600 photo) | 4.9 s | 0.09 s |
| `mask` (1 point) | 2.5 s | 13–57 ms |
| `mask` (new point count) | ~0.5 s (shape respecialization) | ~15 ms after |

The wrapper compiles `.mlpackage` → `.mlmodelc` once and caches it in
`Caches/SAM2CompiledModels`, so cold cost is first-launch-only. Expect the
first encode after install to take seconds on device too — show progress UI.
Note: the mask decoder prints a scary-but-harmless `E5RT ... conv_transpose`
message at load (flexible-shape probing); predictions are unaffected.

## Shipping the weights (App Store)

~94 MB of weights. Options, in order of recommendation:

1. **First-run background download** (recommended): ship the app tiny; on
   first launch download from our CDN (or straight from the HF `resolve/main`
   URLs, pinned by sha256 as in `scripts/download-models.sh`) into
   Application Support (mark excluded-from-backup), then compile+cache.
   `SAM2Segmenter.init(modelsDirectory:)` already takes any directory.
2. **On-Demand Resources**: Apple-hosted, but ODR content is purgeable and
   capped per tag; a purge would silently break offline use until re-fetch.
   Workable if we copy ODR content out to Application Support on first access.
3. **Bundle them**: simplest, but +94 MB IPA (over the 200 MB cellular-
   download courtesy threshold when combined with the rest of the app; App
   Store hard limits are far higher). Fine for TestFlight/dev builds — add the
   three `.mlpackage` folders as bundle resources; Xcode compiles them to
   `.mlmodelc` at build time and `modelsDirectory: Bundle.main.resourceURL!`
   just works (the loader prefers `.mlmodelc`).

For dev builds now: point `modelsDirectory` at the app bundle after adding
`Models/*.mlpackage` to the target, or at the repo `Models/` dir when running
on Mac (tests/harness).

## Simulator caveat: the mask decoder returns empty masks

On the iOS **simulator** (verified: iOS 26.5 runtime, Xcode 26.6, arm64 Mac)
the mask decoder *executes* but its mask branch produces all-zero logits:
`scores` come back plausible (0.09–0.74) while every `low_res_masks` value is
exactly 0, so the decoded mask is empty. The image encoder and prompt encoder
outputs are healthy. The identical Swift + models + fixture + prompt produce
inkFraction ≈ 0.045 on macOS (and the models are published by Apple for
device use). Upstream report of the same shape-inference failure:
https://huggingface.co/apple/coreml-sam2.1-tiny/discussions/1

Everything tried, all still zeros on the simulator:

- compute units `.cpuOnly`, `.cpuAndGPU`, `.all`, `.cpuAndNeuralEngine`
- Xcode-precompiled `.mlmodelc` vs runtime `MLModel.compileModel`
- `MLOptimizationHints.specializationStrategy = .fastPrediction`
- 1-point and 2-point prompts; fresh contiguous fp32 input buffers
- patching the decoder spec to drop the `conv_transpose` ops' redundant
  `output_shape` input (what the E5RT load warning suggests). The patched
  model is bit-identical to the original on macOS but still zeros on the
  simulator — the E5RT complaint just shifts to "tensor_buffer has known
  strides while the model has FlexibleShapeInfo", pointing at the
  flexible-shape (enumerated 1–16 point) compilation itself. Forcing the
  spec static breaks the model (symbolic dims are baked into downstream
  consts), so that path needs a full MIL round-trip — not worth it for a
  simulator-only defect.

Consequences for this repo:

- `scripts/sam-macos-check/run.sh` compiles `SAM2Segmenter.swift` for macOS
  and asserts the fish-body tap yields inkFraction 1–30%. This is the
  machine-local proof that the pipeline works.
- `SAM2SegmenterTests.fishBodyTapYieldsTightMask` runs the full pipeline in
  the simulator; when the decode comes back empty **on the simulator** it
  records a known issue instead of failing (strict on device / fixed runtimes).
- The refine-mask UI treats an empty decode as "no mask" (hint to re-tap,
  "Use Outline" stays disabled), so the simulator defect degrades to the
  same UX as a missed tap; `RefineMaskUITests` skips the Use-Outline leg
  when the mask never arrives.

## Known limitations / findings from the fish-photo fixture

- **Prompt placement matters a lot on line drawings.** A tap on blank paper
  *inside* the drawn outline (e.g. the suggested (700, 950) trace-space point)
  makes SAM segment the paper/shadow region (~48% of the frame) instead of the
  drawing. A tap on the inked subject body itself gives a clean, tight mask
  (verified: 100% of mask pixels inside the drawing bbox, ink fraction 4.5%,
  visually confirmed sticker-quality fish outline). UX should prompt the kid
  to "tap ON the drawing", and treat a mask covering >~30% of the frame as a
  likely miss (offer re-tap / add a negative point).
- With a single tap SAM returns the *pen-bounded region* it hits: tapping the
  fish selects the fish body, not the enclosing drawn circle. To capture a
  compound drawing (circle + caption text) either add taps on each part
  (multi-point works, up to 16) or use a box prompt over the whole drawing.
- Uniform shadows/gradients on paper are SAM's main distractor; a negative
  tap on the background reliably suppresses them.
- Mask logits are 256x256 upsampled to full resolution — very fine pen
  wiggles (< ~8 px at 2000 px image height) get smoothed. That is acceptable
  (arguably desirable) for a cut outline that will be offset anyway.
- Prompt encoder max 16 points; `mask(points:)` throws on 0 or >16.
- Models were converted by Hugging Face with Apple (published under the
  `apple` org, referenced by Apple's own model gallery); float16 precision.

## Files

- `scripts/download-models.sh` — fetch + verify weights into `Models/`.
- `DrawNCut/Segmentation/SAM2Segmenter.swift` — the wrapper (no app-internal
  imports; compiles standalone for macOS 14+ and iOS 17).
- `SegmentationMask { width, height, pixels: [Bool] }` — bridge this to
  `BinaryBitmap` in the trace pipeline.
