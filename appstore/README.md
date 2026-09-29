# App Store listing

What App Store Connect holds for Draw'n'Cut is a copy of this folder. Edit
here, push with the scripts; never edit in the web UI and forget to bring it
back.

| File | Role |
|---|---|
| `listing.json` | Every text field, the categories, content rights, the 4+ age answers, the review contact and notes |
| `upload_listing.py` | Pushes `listing.json` through `scripts/lib/asc.py`. `--dry-run` prints the payloads |
| `screenshots/iphone-65/*.jpg` | iPhone 6.5" (1284×2778), from the `DrawNCut Shots iPhone 6.5` simulator (iPhone 14 Plus) |
| `screenshots/ipad-13/*.jpg` | iPad 13" (2064×2752), from the `DrawNCut Shots iPad 13` simulator (iPad Pro 13-inch M5) |
| `upload_screenshots.py` | Replaces the two screenshot sets in App Store Connect with these files |

## Taking the screenshots

`DrawNCutUITests/StoreScreenshotTests` drives the real app on a simulator and
attaches full-resolution screenshots. It launches with a bundled real photo
and the subject mask that was made for it on a device, because the
simulator's segmentation returns empty masks and a trace without a mask has
no cut line.

```sh
xcodebuild build-for-testing -project DrawNCut.xcodeproj -scheme DrawNCut \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData-Shots
xcodebuild test-without-building -project DrawNCut.xcodeproj -scheme DrawNCut \
  -destination 'id=<simulator udid>' -derivedDataPath DerivedData-Shots \
  -only-testing:DrawNCutUITests/StoreScreenshotTests -resultBundlePath out.xcresult
xcrun xcresulttool export attachments --path out.xcresult --output-path export/
```

Then convert the attachments to JPEG (App Store Connect refuses alpha) into
`screenshots/<size>/`. Set the status bar first so every shot reads 9:41,
full battery: `xcrun simctl status_bar <udid> override --time 9:41
--batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4`.

## What the scripts never do

Submit for review, change pricing, or touch App Privacy. Those are Ali's.
