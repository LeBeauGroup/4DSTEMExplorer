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
| `embed-plugins.sh` | Builds every example into the app, from the Xcode build phase. |
| `Examples/RadialProfile` | Reads the displayed pattern, returns a plot. |
| `Examples/DetectorVariance` | Sweeps the whole stack, returns a computed image. |
| `Examples/TiltCorrectedBF` | Tilt-corrected bright field — see below. |
| `Examples/SingleElectronHistogram` | Single-electron counting histogram — see below. |
| `Examples/PowerCepstrum` | Exit-wave power cepstrum and strain mapping — see below. |
| `Examples/AberrationCorrectedBF` | Aberration-corrected bright field, GPU accelerated — see below. |
| `Examples/Calibration` | Pixel size and scan affine transform from a known lattice — see below. |
| `TestData/` | Generator for an EMD file with known aberrations, to check tcBF against. |

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

All of it is quoted in the file's own units. When the dataset carries a scan
step and a diffraction step, the control asks for **Defocus (nm)**, the focus
curve is plotted against nanometres, and the fitted aberrations are lengths;
without a calibration the same things are in scan pixels of displacement at the
edge of the disc. The two are never mixed in one readout.

It opens as a live window. The displacement slider always drives the
reconstruction; **Auto Defocus** searches for the sharpest focus and leaves what
it found in the slider, so you can then explore either side of it. The search
also runs by itself the first time a given disc and binning are used — otherwise
the opening view would sit at zero defocus, which is just the uncorrected sum —
and once for each new binning after that. Dragging the slider refocuses against
the cached virtual images, the same interaction as the detector radius slider in
the main window; changing the detector or the binning is what forces a rebuild.

### Aberration correction

**Correct for** goes beyond defocus. The displacement of the image formed at
tilt `t` is the gradient of the aberration function, so each aberration
contributes a fixed vector polynomial in `t` with one free coefficient —
defocus is linear in `t`, twofold astigmatism adds a second linear term, coma
and threefold are quadratic, spherical is cubic. Because the coefficients enter
linearly this is a least-squares fit, not a search through many dimensions.

The field is *measured* rather than searched: each virtual image is
cross-correlated against the defocus-corrected sum, and the aberration
gradients are fitted to the resulting shifts. Bootstrapping from the defocus
result keeps the residuals to a few scan pixels, which is why a short direct
search suffices and no FFT is involved. Fitting rather than applying the raw
measurements matters — at most eight parameters against hundreds of
measurements averages away correlation noise, and the model cannot represent a
displacement field that no aberration could produce.

**Return ▸ Aberration fit** gives the coefficients, the measured field, the
residual, and what fraction of the field the model explains. That last number
is the one to check: if the fit explains little, the correlation locked onto
noise rather than the specimen, and the result says so.

The measurement runs twice: the first pass re-forms the reference from what it
found and measures again. That matters because the defocus bootstrap is furthest
off exactly when there is astigmatism to find — with two line foci the sharpness
search settles on one of them rather than the mean, so the first reference is
itself astigmatic. The correlation window is sized from the displacement across
the disc for the same reason; a fixed few pixels clips the cases that most need
correcting.

`TestData/` generates an EMD file with a defocus of 20.0 nm and 8.0 nm of
astigmatism at 30°. The plugin recovers 20.0 nm and 7.98 nm at 29.9°, explains
94 % of the measured field, and sharpens the image 75× over the uncorrected sum
against 22× for defocus alone.

**Bright-field disc from** lists **Pattern COM** followed by the detectors
currently configured, each with its name and shape. Pattern COM works the disc
out from the mean diffraction pattern; picking a detector uses its centre and
outer radius instead. The list is built from the dataset when the window opens,
so a detector added afterwards needs the plugin reopening — one removed
afterwards is reported by name rather than silently ignored.
**Detector binning** trades accuracy for speed and memory — 2 is a good default;
4 and above start to reintroduce the blur being removed. If the reported
displacement lands at the end of the search range, widen it. **Return ▸ Focus
curve** plots sharpness against displacement, which is the quickest way to see
whether the search found a real peak, and **Uncorrected sum** gives the plain BF
image for a side-by-side comparison.

Against a synthetic dataset built with a known displacement of 3.00 scan pixels
(234.4 nm defocus), the plugin recovers 2.98 px / 232.5 nm and sharpens the
image 4.6× over the uncorrected sum.

The per-frame path is vectorised with Accelerate, which is what keeps the slider
interactive. On a 192×192 scan with a 96×96 detector and a 32 px disc: the first
run (build plus a 41-step search) takes 0.48 s, a repeat search on the cached
virtual images 209 ms, and a slider move 22 ms.

## Aberration-corrected bright field

`Examples/AberrationCorrectedBF` corrects the bright-field transfer function
itself, where `TiltCorrectedBF` corrects only the displacement it produces. It
follows the method used by
[fast-acbf](https://github.com/chiahao3/fast-acbf) in the
[py4D-browser plugin](https://github.com/chiahao3/py4D-browser-fast-acbf) of the
same name.

The distinction matters. tcBF translates each virtual image and sums, which
cancels the part of the aberration phase that is linear in the specimen's
spatial frequency. Everything beyond that survives, including the sign reversals
of the contrast transfer function. acBF builds the full complex transfer for
every bright-field pixel `t` over the whole scan-frequency grid,

    T_t(q) = -i [ A(q-t)·e^(-i(χ(t) - χ(t-q)))  -  A(q+t)·e^(+i(χ(t) - χ(q+t))) ]

and then either aligns the phases before summing (`T/(|T|+ε)`, "phase only") or
inverts the whole system as a regularised matched filter,
`Σ T_b Î_b / (Σ|T_b|² + λS_ref)` ("complex inversion"). tcBF is also offered, done
as an exact Fourier phase ramp rather than by interpolation, so the three can be
compared on the same data.

### Why it is fast

The inverse transform is linear, so

    Σ_b IFFT( Î_b · W_b )  =  IFFT( Σ_b Î_b · W_b )

Every mode has that form and differs only in the weight `W_b`. So each virtual
image is transformed once when the stack is built, every reconstruction is a
single accumulation in Fourier space, and exactly one inverse transform runs at
the end no matter how many virtual detectors there are. That leaves the inner
loop purely elementwise, which is what makes the Metal path a direct port — and
what makes refinement, which needs hundreds of reconstructions, affordable.

The shader is compiled at run time from source, because the offline Metal
compiler ships with Xcode rather than the command line tools. If Metal is
unavailable the CPU path computes the same quantity in double precision; the two
agree to within 1e-6 of full scale.

### Aberrations and orientation

Coefficients use the Krivanek `(n, m)` expansion in ångström, with `χ` in
radians and `α = kλ`. Only `C1` and `A1` get their own controls; higher orders
are found by refinement and listed in the **Aberration report** output.

Refinement maximises an image-sharpness metric — Sobel, Laplacian variance or
normalised variance — rather than cross-correlating virtual images the way
`TiltCorrectedBF` does. That works for aberrations which blur rather than shift,
at the cost of a full reconstruction per evaluation. Each search is a coarse
sweep followed by a local method, because the objective is oscillatory and a
purely local search settles into whichever maximum it started nearest. The
coefficients are then polished together with a simplex, in units of "one radian
of phase at the aperture edge" so that a defocus and a `C3` — four orders of
magnitude apart in ångström — are comparably scaled.

Two things worth knowing before trusting a number it reports:

- A term contributing much less than about a tenth of a radian at the aperture
  edge cannot be measured from sharpness at all. Read a value reported for one
  as noise.
- The scan rotation and the astigmatism azimuth are partly degenerate. Rotating
  the frame and the aberrations together rotates the result without blurring it,
  and no isotropic metric can see the difference. Refine orientation *before*
  aberrations, and fix the rotation from a known specimen direction when the
  absolute angle matters.

### Requirements

acBF works in physical units throughout, so it needs a scan step, a diffraction
step and an accelerating voltage. The first two come from the file's
calibration; the voltage comes from the file when it records one and is
otherwise typed in. Without them the plugin refuses to run rather than guessing.

Memory scales as virtual detectors × scan pixels. The detector binning control
is the lever; the plugin refuses up front, with a suggested binning, rather than
thrashing.

## Calibration

`Examples/Calibration` measures the pixel size, and the affine transform of the
scan, against a lattice whose spacings and angle you already know.

Three things come out of one observation — where the lattice peaks are — and
differ only in what those peaks mean:

- **Real-space pixel size**, from the periodicity of a computed image. The image
  is windowed and transformed, and the Fourier peaks are the reciprocal lattice.
- **Diffraction pixel size**, from the spacing of Bragg reflections in a
  pattern. A pattern is already reciprocal space, so the peaks are measured
  directly, relative to the undiffracted beam. With an accelerating voltage on
  hand this is also reported in mrad per pixel.
- **The affine transform**, from how the measured lattice geometry differs from
  the geometry it is known to have.

It runs in a live window: the picture redraws as you adjust, so the exclusion
zone and the detected lattice can be set by eye rather than guessed. The
transform is cached across re-runs, so a control drag costs a peak search rather
than an FFT — about 3 ms.

The **Detected lattice** view draws in colour over the greyscale data: a red
circle for the exclusion zone, red crosses on the two primitive vectors and
their negatives, and a red dot on every other lattice point the fit predicts.
Those dots landing on observed peaks is the confirmation that the fit describes
the whole pattern and not just the two spots it was built from. Markers are
drawn in colour rather than by brightening pixels, because a marker made of
bright pixels is indistinguishable from a peak — which is exactly the judgement
the picture exists to support.

**Window** controls the taper applied before the transform. Tapering suppresses
the bright cross the crop edges put through the origin, at the cost of
broadening every peak — Hann roughly doubles the peak width against no window.
Measured against synthetic lattices, though, Hann still locates peaks most
precisely of the three, and it is the only choice that survives a lattice
aligned with the raster, whose peaks sit on the very axes the untapered cross
runs along. Turn it off when the lattice is off-axis and you want the sharpest
peaks to look at.

The lattice parameters are text fields rather than sliders: a spacing is a
number you know and type. (A number control draws a slider only when it declares
both a minimum and a maximum, so leaving those off gives the text box alone.)
The exclusion radius keeps its slider, being the thing you explore.

The third is why the first two are not the whole story. A raster is not
necessarily square or orthogonal — the scan coils have their own gain and
cross-talk — so one number cannot describe the mapping from pixels to ångström.
Measuring two lattice vectors rather than one length gives the full 2×2 matrix,
and separates the scale from a distortion that would otherwise be folded into it
invisibly. The report gives the matrix, and its polar decomposition into a
rotation, a mean pixel size, an anisotropy and a shear. **Corrected image**
resamples the computed image with the distortion undone.

Two properties of the fit that the report also states, because a number without
them can be over-read:

- **Rotation is determined only up to the lattice's symmetry.** Nothing in an
  image fixes an absolute orientation, so the fit places the first known vector
  along +x; a square net may equally report 0°, 90°, 180° or 270°. Pixel size,
  anisotropy and shear carry no such ambiguity.
- **The reported rotation is the rotation of the fitted map, not the scan
  rotation.** When the raster is sheared the two differ, because a polar
  decomposition attributes part of an asymmetric shear to rotation.

### Handing a calibration back

A plugin cannot change the application's state, and should not be able to: a
calibration changes how every subsequent number is read. Instead it *offers*
one, and the host applies it only when the user accepts.

```swift
return FDSResult.withCalibration(result,
                                 scanStepNanometers: 0.0374,
                                 summary: "Measured from the computed image: …")
```

Pass only what was measured — a nil leaves that part of the host's calibration
alone rather than clearing it. A live window whose plugin has offered a
calibration shows **Accept** and **Cancel** in place of **Run**: at the end of a
measurement the question is whether to keep the answer, not whether to compute
it again. Accepting confirms first, showing each value against what it replaces,
because a calibration is easy to accept by reflex.

### How the lattice is pinned down

Three stages, each fixing a way the previous one can be fooled.

**Peak position** comes from a paraboloid fitted to the neighbourhood of each
local maximum, in the logarithm. Two one-dimensional fits would be cheaper but
carry no cross term, so a peak that is elliptical and tilted — exactly what
sheared or anisotropic sampling produces, the case this plugin exists to
measure — comes out biased.

**Basis selection** scores every candidate pair by how much of the observed
intensity sits on the lattice it generates, then takes the coarsest such
lattice, then the shortest pair among those. All three criteria are needed. A
finer lattice always explains at least as much as the true one, so explanatory
power alone can never rule out a spurious half-spacing; and a lattice has
infinitely many bases of the same determinant, so area cannot separate `(1,0)`
with `(1,1)` from `(1,0)` with `(0,1)` — picking arbitrarily returns the right
lattice described by the wrong vectors, 45° out.

**Basis refinement** then re-fits to every peak the lattice explains, by
weighted least squares on the integer indices. The pair chosen above rests on
two measurements however carefully each was located; the far peaks constrain the
basis best, since the same absolute error in position is a smaller relative
error over a longer vector. Weighting by intensity matters — a bright peak's
position is far better determined than a faint one's, and weighting them equally
lets the noisiest high orders pull an already-good fit off. Measured against
synthetic lattices this improves the spacing about five-fold and the angle by up
to thirty-fold.

Peaks are selected **shortest first** among those above an intensity threshold,
not strongest first. The primitive vectors of a lattice are its shortest
independent ones, so ranking by intensity can discard exactly what is being
looked for — which in a pattern whose reflections are of comparable brightness
yields a lattice several times too coarse, and a calibration that looks entirely
reasonable.

## Power cepstrum (EWPC)

`Examples/PowerCepstrum` maps strain through the exit-wave power cepstrum,
after Padgett et al., *Ultramicroscopy* **214** (2020) 112994. Its
**Citations…** button has the full list.

A nanobeam diffraction pattern is, near enough, the lattice factor multiplied by
everything else — probe, structure factor, dynamical scattering. A logarithm
turns that product into a sum, and Fourier transforming the log separates the
periodic part from the smooth part:

    EWPC(r) = | FFT{ log( I(k) + ε ) } |

The result has the units of length and its peaks sit at the **real-space**
interatomic vectors, so the matrix formed by two peaks *is* the local lattice —
no reciprocal-space inversion.

**Why not just fit the Bragg disks.** Disk fitting wants disks that are
separated, round and unsaturated. Overlapping disks, strong dynamical contrast
and a large convergence angle all change the *amplitude* of the diffraction
pattern rather than its periodicity, so they leave the cepstral peak positions
alone. That is what makes this work on thick or strongly scattering specimens.

The workflow is: **Return ▸ Mean cepstrum** to see where the peaks are, then
**Peak report** for their coordinates, then a strain component. Leaving the four
peak boxes at 0 picks the two strongest independent peaks automatically, which
is usually right. Strain is measured against the mean lattice of the scan, so
the maps are relative and centred on zero.

Points worth knowing:

- **Log floor** is the ε in `log(I + ε)`, as a fraction of the mean pattern's
  maximum. It stops empty pixels dominating; too large flattens the pattern and
  weakens the peaks.
- **Apodise** tapers the detector edge. Without it the sharp cut-off transforms
  into a cross through the middle of the cepstrum, right where the low-order
  peaks are.
- **Zero-pad factor** interpolates the cepstrum for easier peak location. It
  does not add information, and it costs time as the square.
- **Accelerating voltage** only converts cepstral pixels to ångström for the
  report. Strain is a ratio and never depends on it.
- Switching between strain components is instant; the transform is cached.

Against a synthetic crystal with deliberately overlapping disks (16 px lattice
spacing, 9 px disk radius) and a planted εxx sweeping −1 % to +1 %, the peaks
land at radius 15.99 px where the lattice predicts 16.0, the recovered strain
tracks the planted value with slope 0.999, εyy stays flat at 1×10⁻⁴, and the
scatter within a column is 1.3×10⁻⁴ strain.

## Single-electron histogram

`Examples/SingleElectronHistogram` measures the detector's single-electron
level — the gain calibration for a direct electron detector.

A primary electron deposits charge across a small group of neighbouring pixels,
so no single pixel value is quantised; the *sum* over the whole cluster is. The
plugin thresholds each pattern above the read noise, groups the surviving pixels
into contiguous clusters, integrates each one, and histograms the totals. The
first peak is one electron; peaks at 2× and 3× are coincidences.

**An annular detector is required.** Events can only be separated where charge
clouds rarely overlap, and inside the bright-field disc the occupancy is orders
of magnitude too high — clusters merge into a continuum with no single-electron
peak at all. The plugin refuses a bright-field detector, and also refuses an
annular one whose inner radius still covers the disc. Leave **Detector** at 0 to
use the selected annular detector.

The noise floor is measured from the data rather than assumed: median and MAD
over aperture pixels from a sample of patterns, which stay robust when a few
percent of pixels carry events. That floor is subtracted from every pixel before
integrating — leaving it in would add the detector offset once per pixel and
make the integral scale with cluster size instead of deposited charge.

Points worth knowing:

- **Threshold** trades completeness against noise. Too high and only the
  brightest pixels of each cloud are captured, so the peak reads low — use
  **Return ▸ Cluster size histogram** to check the clouds are the size you
  expect (a mean near 1 px means the threshold is clipping them).
- Clouds straddling the aperture edge are discarded by default; they are only
  partly measured and would bias the histogram low.
- **Return ▸ Counted ADF image** maps events per probe position — a counted,
  dose-efficient dark-field image.
- The result warns when aperture occupancy is high enough that clouds overlap.

Against a synthetic detector depositing exactly 200 ADU per electron over a
4-pixel cloud on a 100 ADU offset with 3 ADU read noise, the plugin recovers a
peak of 201.3 ADU and a modal cluster size of 4 px. Raising the threshold to 15σ
drops the peak to 140.3 — exactly the two brightest pixels of the deposited
cloud, which is the clipping behaviour described above.

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
| `FDSParameter.button(_:label:help:)` | `NSNumber` (Bool) — true only on the run the press started |

A button is an action, not a setting. It reads true for exactly one run and
false on every other, so a plugin can treat it as "do this now" rather than as a
mode the user has to remember to turn off again. In a live window a press runs
immediately rather than waiting for the debounce that smooths out slider drags.

Omit `pluginParameters` (or return an empty array) and the plugin runs
immediately with no sheet.

`pluginParameters` is read once at load time, with no dataset in hand, so it
cannot know what units the open file carries. Implement `parameters(for:)` as
well to be asked again once there is one:

```swift
public func parameters(for host: FDSHostContext) -> [[String: Any]] {
    guard host.scanStepNanometers > 0, host.diffractionStepMilliradians > 0 else {
        return pluginParameters                  // uncalibrated: ask in pixels
    }
    return calibratedParameters                  // ask in nanometres
}
```

Do this rather than presenting a control in one unit and reporting the result in
another. A plugin should speak one language: physical units when the file
supports them, pixels when it does not, and never a mixture.

### Shipping plugins inside the app

The app target has an **Embed Plugins** build phase that runs
`PluginSDK/embed-plugins.sh`, which builds every folder under `Examples/` into
`4DSTEM Explorer.app/Contents/PlugIns`. Those load automatically — the app
searches its own `PlugIns` folder as well as the user's.

Adding a plugin to the shipped set is just creating the folder; the phase picks
up anything with a `plugin.conf`. Nothing needs to be registered in the Xcode
project, because the plugins are not Xcode targets.

The script does three things a plain loop would not:

- **Signs with the app's identity**, taken from `EXPANDED_CODE_SIGN_IDENTITY`.
  Nested code inside a signed app has to carry a signature from the same
  identity or the app fails to validate at launch.
- **Builds only `$ARCHS`**, so a debug build does not pay for a universal
  plugin it will not run. A release build still produces both slices.
- **Skips unchanged plugins.** A clean build of all six takes about 20 seconds;
  an incremental one where nothing changed takes 0.1 s. Editing a `.swift`,
  `.bib` or `plugin.conf` rebuilds that plugin; editing
  `FourDSTEMPluginAPI.swift` rebuilds all of them, since it is compiled into
  each.

A plugin that fails to build fails the app build, rather than quietly shipping
an app that looks complete and is missing a feature. The same is true of a
malformed `.bib`.

Run it outside Xcode by giving it a destination:

```bash
./PluginSDK/embed-plugins.sh /path/to/Some.app/Contents/PlugIns
```

**A user's own copy still wins.** The app reads its user plugins folder first
and skips a bundled plugin whose identifier is already claimed — so installing a
newer build of a shipped plugin overrides it. The shadowed bundle is never
opened at all, which matters: two bundles defining the same `@objc` class both
register it with the Objective-C runtime, and the runtime warns that this causes
"spurious casting failures and mysterious crashes".

### Citations

Put a `.bib` file in the plugin's source folder. `build-plugin.sh` validates it,
copies it into `Contents/Resources`, and the app shows a **Citations…** button
beside that plugin's controls — in both the parameter sheet and the live window.
A plugin with no `.bib` gets no button and no Resources folder. There is no API
to call and nothing to declare in Swift.

```
Examples/MyPlugin/
    plugin.conf
    MyPlugin.swift
    MyPlugin.bib      <- becomes the plugin's citations
```

The window lists the entries, links each DOI, and offers **Copy BibTeX** and
**Export BibTeX…**. What it exports is your file, byte for byte, under a
provenance comment. The app parses the file to display it but never re-emits it,
so an exported bibliography cannot differ from the one you wrote and tested.

Ordinary BibTeX, with two conventions:

- **Order matters.** The first entry is the one to cite first, and it is shown
  emphasised.
- **`annote` says why.** It is displayed above each entry ("The tcBF method",
  "Reference implementation this follows") and is a standard field the common
  styles ignore, so the file stays plain BibTeX.

```bibtex
@article{yu2025tcbf,
  author  = {Yu, Yue and Spoth, Katherine A. and Muller, David A.},
  title   = {{Dose-efficient cryo-electron microscopy for thick samples}},
  journal = {Nature Methods},
  volume  = {22},
  number  = {10},
  pages   = {2138--2148},
  year    = {2025},
  doi     = {10.1038/s41592-025-02834-9},
  annote  = {The tcBF method}
}
```

Prefer `@misc` with `howpublished = {\url{...}}` over `@software` for code.
biblatex understands `@software`, but classic BibTeX discards entry types it
does not know — the entry vanishes from the bibliography with no error, which is
worse than typing it a little less precisely.

The build fails, rather than shipping, if the file has unbalanced braces, no
entries, an entry without a cite key, or duplicate cite keys. A duplicate key is
worth catching early: BibTeX keeps the first and silently drops the rest.

The parser handles `@string` macros, `@comment` blocks, quoted and braced
values, `#` concatenation, and the usual LaTeX accents and escapes, so author
names such as `M{\"u}ller` display correctly. Include your own entry for
4DSTEM Explorer if you want users to cite the app alongside the method.

### Live plugins

Declaring `pluginSupportsLiveUpdate` replaces the sheet-then-window flow with a
single window: controls on the left, result on the right, re-running as the user
moves a control. Only claim it if repeated runs are quick.

```swift
public var pluginSupportsLiveUpdate: Bool { true }
```

The host makes that practical:

- **Runs are serialised and never re-entrant**, so the same instance can cache
  across calls with no locking. Key the cache on the parameters the expensive
  part actually depends on and rebuild only when those change.
- **Moving a control cancels the run in flight** and schedules another after a
  short pause, so dragging a slider does not queue a run per tick. Poll
  `isCancelled` often, and `return nil` when it goes true — the previous result
  stays on screen. Only commit a cache built from a *complete* pass.
- **`FDSResultKey.parameters`** writes values back into the controls. A plugin
  that measures something can leave the control sitting at what it found; the
  writeback does not itself trigger another run.

The state a plugin sees is re-snapshotted every run, so detector edits in the
main window are picked up rather than frozen when the window opened.

### Reading the data

Everything comes off `host`:

- **Geometry** — `scanWidth`, `scanHeight`, `patternWidth`, `patternHeight`,
  `patternPixelCount`, `fileName`, `filePath`.
- **Calibration** — `scanStepNanometers`, `diffractionStepMilliradians` and
  `accelerationKilovolts`, each `0` when the file is uncalibrated. Treat `0` as
  "unknown" and fall back to your own default rather than using it as a value.
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
| `FDSResult.plot(x:y:title:xLabel:yLabel:message:)` | Line plot — drag to zoom the x axis, hover to read values, exports as CSV |
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
