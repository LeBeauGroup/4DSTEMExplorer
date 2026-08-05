# Test data with known aberrations

`make-aberrated-tcbf.swift` writes an EMD file whose bright-field disc carries a
defocus, a twofold astigmatism and a small third-order term that were put there
on purpose, so the Tilt-Corrected Bright Field plugin can be checked against
numbers rather than against how the picture looks.

## Build and run

```bash
cd PluginSDK/TestData
xcrun swiftc -O \
  -I/opt/homebrew/opt/hdf5/include -L/opt/homebrew/opt/hdf5/lib -lhdf5 \
  -import-objc-header "../../4DSTEM Explorer/HDF5Kit/HDF5Kit-Bridging-Header.h" \
  -o make-aberrated-tcbf make-aberrated-tcbf.swift
./make-aberrated-tcbf ~/Downloads/tcBF-test-aberrated.emd
```

Takes about a minute and produces roughly 70 MB (chunked and deflated, which
also exercises the reader's compressed path).

## What is in it

| | |
| --- | --- |
| Scan | 96 × 96 probe positions, 0.5 Å each |
| Patterns | 48 × 48 detector pixels, 1.25 mrad each |
| Bright-field disc | radius 16 px = 20 mrad, centred |
| Specimen | Gaussian columns on a staggered lattice, 0.4 nm spacing, with one vacancy and one heavy column |

**The planted aberrations**

| | value | as edge displacement |
| --- | --- | --- |
| Defocus C1 | 20.0 nm | 8.00 scan px |
| Astigmatism A1 | 8.0 nm at 30° | 3.20 scan px |
| Third order | — | 1.00 scan px |

The same numbers are written into the file as a `/truth` group, so they travel
with the data.

## Checking the plugin against it

Open the file, then run **Plugins ▸ Tilt-Corrected Bright Field**. With
**Bright-field disc from** on `Pattern COM` and **Correct for** on
`Defocus + astigmatism`, **Return ▸ Aberration fit` should report:

```
Fitted aberrations
  defocus 20.0 nm, astigmatism 8.0 nm at 30°
Explained       94%
Coefficients
  C1 defocus 20.0 nm
  A1 astigmatism a 4.0 nm        (8.0 · cos 60°)
  A1 astigmatism b 6.9 nm        (8.0 · sin 60°)
```

Things worth trying:

- **Auto Defocus alone lands near 28 nm, not 20.** That is not a bug. With 8 nm
  of astigmatism the two line foci sit at 12 and 28 nm, and a single defocus
  cannot be at both; the sharpness search settles on one of them. Switching to
  `Defocus + astigmatism` is what recovers the true 20 nm.
- **Compare the images.** Against the uncorrected sum, defocus correction alone
  sharpens about 22×, and adding astigmatism about 75×. The lattice, the vacancy
  and the heavy column should all be obvious in the corrected image and not in
  the uncorrected one.
- **Drag the defocus slider** either side of 20 nm to watch it blur and sharpen
  live.
- **Return ▸ Focus curve** should peak near 28 nm — again, the line focus, which
  is why the curve alone is not the whole story on an astigmatic specimen.

## Changing what gets planted

The aberrations are the constants at the top of the generator:

```swift
let defocusNm    = 20.0
let astigNm      = 8.0
let astigDegrees = 30.0
let cubicEdgePx  = 1.0
```

Keep the total edge displacement comfortably inside the scan — the correction
shifts each virtual image by up to that amount, and shifts approaching the scan
width leave too little overlap to correlate.
