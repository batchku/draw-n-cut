# Draw'n'Cut

Photograph a kid's drawing → get a laser-cuttable DXF.

Draw'n'Cut is an iOS app that turns a phone photo of a hand-drawn picture into
clean vector output: a closed **cut line** around the figure and **engrave
lines** for everything drawn inside it, exported as a DXF ready for a laser
cutter.

Everything runs on-device — segmentation, tracing, and export work with no
network connection and no cloud services.

## How it works

1. **Capture** — photograph the drawing (or import from your photo library).
2. **Select the subject** — tap the figure you want to cut out. Segmentation
   runs on-device with [SAM 2.1 Small](https://github.com/facebookresearch/sam2)
   (Apple's Core ML port). Add plus/minus markers to refine the mask.
3. **Trace** — the photo is adaptively binarized, skeletonized to centerlines,
   and vectorized. The mask's silhouette becomes the red cut loop; the pen
   strokes inside it become blue engrave polylines.
4. **Tune** — three sliders and two touch gestures, nothing else:
   - **Outline** — how faithfully the cut line hugs the mask boundary.
   - **Lines** — which marks survive (speckle and short-stroke filtering).
   - **Smooth** — how curves are drawn, from raw raster fidelity to heavily
     simplified and rounded.
   - **Tap** a blue line to promote it to a cut line (tap again to demote).
   - **Lasso** with the eraser to remove anything; two-finger tap undoes.
5. **Export** — DXF (R12, millimeters) with `CUT` (red) and `ENGRAVE` (blue)
   layers, sized to a physical width you pick.

## Robustness

The trace pipeline is built against real handheld photos, not scans:

- Local adaptive thresholding survives lighting gradients and dark tables.
- A paper-region mask suppresses table texture — gated by an edge-sharpness
  test so a hard shadow across the page is never mistaken for a table edge.
- Faint strokes (light pencil, photos of screens) are re-bridged instead of
  perforating into dashes.
- Filled dots (eyes, freckles) trace as their actual drawn contour.
- Every real-world failure becomes a fixture: the photos in `Fixtures/` are
  actual kid drawings that once broke the pipeline and now guard it.

## Building

Requirements: Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen),
an iPhone running iOS 17+ (the segmentation models want real Neural Engine —
the simulator produces empty masks; there's a test documenting that).

```sh
# 1. Fetch the SAM 2.1 Core ML models (~94 MB, git-ignored)
scripts/download-models.sh

# 2. Generate the Xcode project
xcodegen generate

# 3. Open, set your signing team, build to your phone
open DrawNCut.xcodeproj
```

## Deploying to TestFlight

Requires a paid Apple Developer membership and an App Store Connect API key.

One-time setup:

1. App Store Connect → Users and Access → Integrations → Team Keys →
   Generate API Key (role **App Manager**). Note the Key ID and Issuer ID.
2. Save the downloaded `.p8` as
   `~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8`.
3. Create the app record once: App Store Connect → My Apps → **+** → New App
   (platform iOS, bundle ID `studio.irl.DrawNCut`).

Then every deploy is one command:

```sh
ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=xxxxxxxx-xxxx-... scripts/deploy-testflight.sh
```

The script archives Release, signs with cloud-managed certificates
(`-allowProvisioningUpdates` — no local cert wrangling), uploads to App Store
Connect, and stamps the build number from the git commit count so it's
monotonic and never needs manual bumping.

## Tests

```sh
xcodebuild test -project DrawNCut.xcodeproj -scheme DrawNCut \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:DrawNCutTests
```

The suite covers the raster→vector engine (binarization, skeletonization,
component guards), geometry (contours, simplification, DXF layout), the
session layer (mask confinement, erase/cut-toggle replay, version restore),
and end-to-end traces of every fixture photo.

## Project layout

```
DrawNCut/
  Trace/          raster→vector engine: binarization, skeleton, geometry
  Segmentation/   SAM 2.1 Core ML wrapper + mask PNG bridge
  Cuttability/    element classification, cleanup suggestions
  Features/       SwiftUI screens: capture, refine mask, trace, library, export
  Export/         DXF writer (R12, CUT/ENGRAVE layers)
  Diagnostics/    per-project trace log + preview renderer
DrawNCutTests/    unit + fixture regression tests
Fixtures/         real drawings used as regression tests
Models/           SAM 2.1 mlpackages (populated by scripts/download-models.sh)
scripts/          model download, on-device log watching
```

## Debugging on device

Every project folder in the app's Documents keeps a `diagnostics.log`, the
original photo, the current mask, and a rendered trace preview — pullable
over USB with `devicectl`, no app relaunch needed. `scripts/watch-device.sh`
streams the same log lines live. Each trace logs one line of the decisions
made:

```
traced detail=0.70 smooth=0.40 → 3 elements, 26 polylines, 0 suggestions |
ink=121971 mask=off sep=79 border=19 edge=0
```

## The drawings

The test fixtures are real kid drawings photographed with this app — the
exact frames that once broke the pipeline.
