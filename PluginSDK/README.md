# 4DSTEM Explorer Plugin SDK

Plugins are native macOS `.bundle` packages that 4DSTEM Explorer loads at
launch. A plugin gets read access to the 4D dataset that is already open — the
whole stack, the pattern on screen, the computed image, and the detector
geometry — and returns a computed image, a diffraction pattern, a plot, or text,
which the app opens in its own window with export.

## Contents

| Path | What it is |
| --- | --- |
| `FourDSTEMPluginAPI.swift` | The entire contract. Compile this file into your plugin. |
| `build-plugin.sh` | Compiles a source folder into a signed, universal `.bundle`. |
| `Examples/RadialProfile` | Reads the displayed pattern, returns a plot. |
| `Examples/DetectorVariance` | Sweeps the whole stack, returns a computed image. |
| `Examples/TiltCorrectedBF` | Tilt-corrected bright field — see below. |

## Tilt-corrected bright field

`Examples/TiltCorrectedBF` is a working reconstruction, not just a demo.

Every detector pixel inside the bright-field disc sees the specimen at a
slightly different tilt, so the virtual image it forms is the same image
displaced sideways by `defocus · θ`. An ordinary BF detector sums those
displaced copies, which is exactly why a defocused BF image is blurred. This
plugin shifts each one back before summing: the dose of the whole disc with the
resolution of a single pixel of it.

The displacement is linear in tilt, so one number describes the whole
correction. The plugin parameterises it as the displacement at the edge of the
disc, in scan pixels, and finds it by maximising gradient energy — meaning it
works on uncalibrated data. When the file has a scan step and a diffraction
step, the equivalent defocus is reported in nanometres.

Set **Bright-field disc from** to `0` to detect the disc from the mean pattern,
or to a detector number to use that detector's centre and outer radius.
**Detector binning** trades accuracy for speed and memory — 2 is a good default;
4 and above start to reintroduce the blur being removed. If the reported
displacement lands at the end of the search range, widen it. **Return ▸ Focus
curve** plots sharpness against displacement, which is the quickest way to see
whether the search found a real peak, and **Uncorrected sum** gives the plain BF
image for a side-by-side comparison.

Against a synthetic dataset built with a known displacement of 3.00 scan pixels
(234.4 nm defocus), the plugin recovers 2.98 px / 232.5 nm and sharpens the
image 4.6× over the uncorrected sum.

## Quick start

```bash
cd PluginSDK
./build-plugin.sh Examples/RadialProfile
```

That builds the bundle and installs it into the app's plugins folder. In the
app, choose **Plugins ▸ Reload Plugins** and the plugin appears in the menu.

To write your own, copy an example folder, edit `plugin.conf`, and build it:

```bash
./build-plugin.sh MyPlugin              # install into the plugins folder
./build-plugin.sh MyPlugin ./build      # or build somewhere else
```

`plugin.conf` sets four values:

```
NAME=MyPlugin                                  # bundle and executable name
PRINCIPAL_CLASS=MyPluginClass                  # the @objc name of your class
IDENTIFIER=com.example.4dstem.plugin.myplugin  # unique across installed plugins
VERSION=1.0
```

You can also build with Xcode: make a macOS **Bundle** target, add
`FourDSTEMPluginAPI.swift` and your sources, and set `NSPrincipalClass` in the
target's Info.plist. The script exists so you don't have to.

## Where plugins live

```
~/Library/Containers/lebeaugroup.stemexplorer/Data/Library/Application Support/4DSTEM Explorer/PlugIns
```

The app is sandboxed, so this container path — not `~/Library/Application
Support` — is the folder it reads. **Plugins ▸ Show Plugins Folder** opens it,
and **Plugins ▸ Install Plugin…** copies a bundle there for you. Plugins shipped
inside the app (`Contents/PlugIns`) load too; a user-installed plugin with the
same identifier takes precedence.

## Writing a plugin

Your principal class subclasses `NSObject` and conforms to `FDSPlugin`. Give it
a stable Objective-C name with `@objc(...)` so it does not depend on the module
it was built in.

```swift
import Foundation

@objc(MyPluginClass)
public final class MyPluginClass: NSObject, FDSPlugin {

    public var pluginIdentifier: String { "com.example.4dstem.plugin.myplugin" }
    public var pluginName: String { "My Plugin" }
    public var pluginSummary: String { "What it does, in one line." }
    public var pluginAPIVersion: Int { 1 }

    public var pluginParameters: [[String: Any]] {
        [FDSParameter.integer("bins", label: "Bins", defaultValue: 64, minimum: 8, maximum: 1024)]
    }

    public func run(host: FDSHostContext, parameters: [String: Any]) -> [String: Any]? {
        let bins = (parameters["bins"] as? NSNumber)?.intValue ?? 64
        var image = [Float](repeating: 0, count: host.scanWidth * host.scanHeight)
        // ... fill image ...
        return FDSResult.scanImage(image, rows: host.scanHeight, columns: host.scanWidth)
    }
}
```

`run` is called on a background queue with the 4D stack guaranteed resident and
unchanged for its duration. Do not touch AppKit from it.

### Parameters

Declare them with the `FDSParameter` helpers and the app builds a settings sheet
before running. Values come back keyed by the identifier you gave.

| Helper | Value type in `parameters` |
| --- | --- |
| `FDSParameter.number(_:label:defaultValue:minimum:maximum:help:)` | `NSNumber` (Double) — gets a slider when both bounds are given |
| `FDSParameter.integer(...)` | `NSNumber` (Int) |
| `FDSParameter.toggle(...)` | `NSNumber` (Bool) |
| `FDSParameter.choice(_:label:choices:defaultValue:help:)` | `String` |
| `FDSParameter.text(...)` | `String` |

Omit `pluginParameters` (or return an empty array) and the plugin runs
immediately with no sheet.

### Reading the data

Everything comes off `host`:

- **Geometry** — `scanWidth`, `scanHeight`, `patternWidth`, `patternHeight`,
  `patternPixelCount`, `fileName`, `filePath`.
- **Calibration** — `scanStepNanometers` and `diffractionStepMilliradians`, each
  `0` when the file is uncalibrated.
- **The stack** — `copyPattern(row:column:into:capacity:)` writes one pattern
  into a buffer you own; use it when sweeping the scan. `patternData(row:column:)`
  is the allocating equivalent, fine for a handful of positions.
- **What the user is looking at** — `currentPatternData` (the displayed pattern,
  or the marquee average), `currentScanImageData` (the displayed computed image),
  `selectedRow` / `selectedColumn`, and `selectionColumn` / `selectionRow` /
  `selectionWidth` / `selectionHeight` for the marquee.
- **Detectors** — `detectorCount`, `detectorInfo(at:)` for geometry and mode
  keyed by `FDSDetectorKey`, and `detectorMaskData(at:)` for a Float32 mask
  aligned with the patterns.

All `Data` payloads are Float32, row-major. `FDSFloatArray(data)` unpacks them.

### Progress and cancellation

Call `host.reportProgress(_:)` with 0…1 as you go; without it the sheet shows an
indeterminate bar. Poll `host.isCancelled` at a coarse granularity — once per
scan row is right — and `return nil` when it goes true. `host.log(_:)` records a
line that is shown if the plugin ends up reporting an error.

### Returning a result

| Builder | Shown as |
| --- | --- |
| `FDSResult.scanImage(_:rows:columns:title:message:)` | Image window, exports as 32-bit float TIFF |
| `FDSResult.pattern(_:rows:columns:title:message:)` | Same, sized to the detector |
| `FDSResult.plot(x:y:title:xLabel:yLabel:message:)` | Line plot, exports as CSV |
| `FDSResult.text(_:title:)` | Monospaced text, copy or export |
| `FDSResult.failure(_:)` | Alert; nothing else is shown |

`FDSResult.withColor(_:rgba:)` attaches your own RGBA rendering to an image
result — the app displays that instead of its grayscale stretch, and still
exports the numeric values. Returning `nil` means "cancelled" and shows nothing.

## Code signing

Apple silicon will not load unsigned code, so `build-plugin.sh` ad-hoc signs
every bundle. Set `PLUGIN_SIGN_IDENTITY` to sign with a real identity:

```bash
PLUGIN_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build-plugin.sh MyPlugin
```

Loading plugins signed by a different team requires the app to carry
`com.apple.security.cs.disable-library-validation`, which it does.

## Troubleshooting

Bundles that fail to load are listed under **Plugins ▸ Not Loaded** with the
reason. The usual causes:

- **"does not conform to FDSPlugin"** — the class is missing `@objc(...)`, or
  `NSPrincipalClass` in Info.plist does not match the Objective-C class name.
- **"The system refused to load the plugin's code"** — the bundle is unsigned,
  or built only for an architecture this Mac cannot run.
- **"No NSPrincipalClass in Info.plist"** — rebuild with `build-plugin.sh`,
  which writes the key for you.
- **Changes not taking effect** — macOS cannot unload code that is already
  loaded. Replacing a plugin you have run this session needs an app restart;
  the installer says so when it happens.

## Versioning

`FDSPluginAPIVersion` is 1. A plugin declaring a `pluginAPIVersion` higher than
the host's is refused with an explanation rather than loaded. Because the
contract is protocols and dictionaries, additive changes — new host properties,
new result keys — do not break plugins already built.
