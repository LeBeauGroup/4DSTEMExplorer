//
//  make-aberrated-tcbf.swift
//  4DSTEM Explorer — test data generator
//
//  Writes an EMD (HDF5) 4D-STEM dataset whose bright-field disc carries a known
//  defocus, twofold astigmatism and a small third-order term, so the
//  Tilt-Corrected Bright Field plugin can be checked against numbers that were
//  put there on purpose.
//
//  How the data is built
//  ---------------------
//  The specimen is an analytic sum of Gaussian columns on a square lattice, so
//  it can be sampled at fractional positions exactly — the synthetic shifts are
//  not limited by the scan grid. The virtual image formed by the detector pixel
//  at tilt t is the specimen displaced by d(t), where d is the gradient of the
//  aberration function:
//
//      d(t) = C1·t  +  A1 term  +  cubic term
//
//  Summing those displaced copies is what a plain BF detector does, and undoing
//  the displacement is what tcBF does. The truth is written into the file as a
//  `/truth` group so it travels with the data.
//
//  Build and run:
//      xcrun swiftc -O \
//        -I/opt/homebrew/opt/hdf5/include -L/opt/homebrew/opt/hdf5/lib -lhdf5 \
//        -import-objc-header "../../4DSTEM Explorer/HDF5Kit/HDF5Kit-Bridging-Header.h" \
//        -o make-aberrated-tcbf make-aberrated-tcbf.swift
//      ./make-aberrated-tcbf ~/Downloads/tcBF-test-aberrated.emd
//

import Foundation

// MARK: - Geometry and calibration

let scanN       = 96          // probe positions per side
let patternN    = 48          // detector pixels per side
let discRadius  = 16.0        // bright-field disc radius, detector pixels

let scanStepA   = 0.5         // Angstrom per probe position  -> 0.05 nm
let diffStepMr  = 1.25        // mrad per detector pixel      -> disc = 20 mrad

// A shift of k scan pixels per detector pixel of tilt corresponds to a length
// C = k · scanStep / (diffStep in radians).  Here that factor is 40 nm per unit k.
let nmPerK = (scanStepA / 10.0) / (diffStepMr / 1000.0)

// MARK: - The aberrations being planted

let defocusNm      = 20.0                        // C1
let astigNm        = 8.0                         // A1 magnitude
let astigDegrees   = 30.0                        // A1 axis
let cubicEdgePx    = 1.0                         // third-order, as edge shift

let k1 = defocusNm / nmPerK
let astigK = astigNm / nmPerK
let ka = astigK * cos(2 * astigDegrees * .pi / 180)   // grad of (tx²−ty²)/2
let kb = astigK * sin(2 * astigDegrees * .pi / 180)   // grad of tx·ty
let kc = cubicEdgePx / (3 * discRadius * discRadius)  // grad of tx³

/// Where the image formed at tilt (tx, ty) sits, in scan pixels.
func displacement(_ tx: Double, _ ty: Double) -> (Double, Double) {
    var dx = k1 * tx + ka * tx + kb * ty
    var dy = k1 * ty + kb * tx - ka * ty
    dx += kc * 3 * tx * tx
    dy += kc * 3 * ty * ty
    return (dx, dy)
}

// MARK: - Specimen

/// Gaussian columns on a square lattice, with a vacancy and a heavy column so
/// there is something to judge sharpness by eye.
struct Specimen {
    var columns: [(x: Double, y: Double, weight: Double)] = []
    let sigma = 1.6

    init(extent: Int) {
        let spacing = 8.0                      // 0.4 nm at this scan step
        var rng: UInt64 = 0xA1B2C3D4
        func jitter() -> Double {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return (Double((rng >> 33) & 0xFFFF) / 65535.0 - 0.5) * 0.35
        }
        var row = 0
        var y = spacing
        while y < Double(extent) - spacing / 2 {
            var column = 0
            var x = spacing + (row % 2 == 0 ? 0 : spacing / 2)   // staggered rows
            while x < Double(extent) - spacing / 2 {
                var weight = 1.0
                if row == 5 && column == 5 { weight = 0 }        // vacancy
                if row == 7 && column == 8 { weight = 1.9 }      // heavy column
                if weight > 0 {
                    columns.append((x + jitter(), y + jitter(), weight))
                }
                x += spacing
                column += 1
            }
            y += spacing
            row += 1
        }
    }

    func value(_ x: Double, _ y: Double) -> Double {
        var total = 0.15                                   // background
        let cutoff = 5 * sigma
        for column in columns {
            let dx = x - column.x, dy = y - column.y
            if abs(dx) > cutoff || abs(dy) > cutoff { continue }
            total += column.weight * exp(-(dx * dx + dy * dy) / (2 * sigma * sigma))
        }
        return total
    }
}

// MARK: - HDF5 helpers

func group(_ parent: hid_t, _ name: String) -> hid_t {
    return name.withCString {
        H5Gcreate2(parent, $0, hid_t(H5P_DEFAULT), hid_t(H5P_DEFAULT), hid_t(H5P_DEFAULT))
    }
}

func writeStringAttribute(_ parent: hid_t, _ name: String, _ value: String) {
    let type = H5Tcopy(H5T_C_S1_g)
    H5Tset_size(type, size_t(max(1, value.utf8.count)))
    H5Tset_strpad(type, H5T_STR_NULLPAD)
    let space = H5Screate(H5S_SCALAR)
    let attribute = name.withCString {
        H5Acreate2(parent, $0, type, space, hid_t(H5P_DEFAULT), hid_t(H5P_DEFAULT))
    }
    if attribute >= 0 {
        _ = value.withCString { H5Awrite(attribute, type, $0) }
        H5Aclose(attribute)
    }
    H5Sclose(space); H5Tclose(type)
}

func writeDoubles(_ parent: hid_t, _ name: String, _ values: [Double], units: String? = nil) {
    var dims: [hsize_t] = [hsize_t(values.count)]
    let space = H5Screate_simple(1, &dims, nil)
    let dataset = name.withCString {
        H5Dcreate2(parent, $0, H5T_IEEE_F64LE_g, space,
                   hid_t(H5P_DEFAULT), hid_t(H5P_DEFAULT), hid_t(H5P_DEFAULT))
    }
    _ = H5Dwrite(dataset, H5T_NATIVE_DOUBLE_g, hid_t(H5S_ALL), hid_t(H5S_ALL),
                 hid_t(H5P_DEFAULT), values)
    if let units = units { writeStringAttribute(dataset, "units", units) }
    H5Dclose(dataset); H5Sclose(space)
}

// MARK: - Write

let outputPath = CommandLine.arguments.count > 1
    ? (CommandLine.arguments[1] as NSString).expandingTildeInPath
    : (("~/Downloads/tcBF-test-aberrated.emd") as NSString).expandingTildeInPath

try? FileManager.default.removeItem(atPath: outputPath)
let file = outputPath.withCString {
    H5Fcreate($0, 0x02 /* TRUNC */, hid_t(H5P_DEFAULT), hid_t(H5P_DEFAULT))
}
precondition(file >= 0, "could not create \(outputPath)")

let root = group(file, "datacube_root")
let cube = group(root, "datacube")

var dims: [hsize_t] = [hsize_t(scanN), hsize_t(scanN), hsize_t(patternN), hsize_t(patternN)]
let space = H5Screate_simple(4, &dims, nil)

// Chunked and deflated: the data is smooth, so this shrinks the file a lot and
// exercises the reader's compressed path at the same time.
let creation = H5Pcreate(H5P_CLS_DATASET_CREATE_ID_g)
var chunk: [hsize_t] = [4, 4, hsize_t(patternN), hsize_t(patternN)]
H5Pset_chunk(creation, 4, &chunk)
H5Pset_shuffle(creation)
H5Pset_deflate(creation, 5)

let data = "data".withCString {
    H5Dcreate2(cube, $0, H5T_IEEE_F32LE_g, space, hid_t(H5P_DEFAULT), creation, hid_t(H5P_DEFAULT))
}
precondition(data >= 0, "could not create the dataset")
writeStringAttribute(data, "units", "pixel intensity")

let specimen = Specimen(extent: scanN)
let centre = Double(patternN) / 2.0
let patternPixels = patternN * patternN

// One scan row at a time, so peak memory stays small.
var row = [Float](repeating: 0, count: scanN * patternPixels)
var rng: UInt64 = 0x5EED
func noise() -> Double {
    rng = rng &* 6364136223846793005 &+ 1442695040888963407
    return (Double((rng >> 33) & 0xFFFF) / 65535.0 - 0.5) * 0.04
}

var memoryDims: [hsize_t] = [1, hsize_t(scanN), hsize_t(patternN), hsize_t(patternN)]
let memorySpace = H5Screate_simple(4, &memoryDims, nil)

print("writing \(scanN)×\(scanN) scan of \(patternN)×\(patternN) patterns")
for ry in 0..<scanN {
    for rx in 0..<scanN {
        let base = rx * patternPixels
        for qy in 0..<patternN {
            let ty = Double(qy) - centre
            for qx in 0..<patternN {
                let tx = Double(qx) - centre
                guard tx * tx + ty * ty <= discRadius * discRadius else {
                    row[base + qy * patternN + qx] = Float(max(0, 0.02 + noise()))
                    continue
                }
                let (dx, dy) = displacement(tx, ty)
                let value = specimen.value(Double(rx) - dx, Double(ry) - dy) + noise()
                row[base + qy * patternN + qx] = Float(max(0, value))
            }
        }
    }

    var start: [hsize_t] = [hsize_t(ry), 0, 0, 0]
    var count: [hsize_t] = [1, hsize_t(scanN), hsize_t(patternN), hsize_t(patternN)]
    let fileSpace = H5Dget_space(data)
    H5Sselect_hyperslab(fileSpace, H5S_SELECT_SET, &start, nil, &count, nil)
    _ = H5Dwrite(data, H5T_NATIVE_FLOAT_g, memorySpace, fileSpace, hid_t(H5P_DEFAULT), row)
    H5Sclose(fileSpace)

    if ry % 16 == 0 { print(String(format: "  %d%%", 100 * ry / scanN)) }
}

// Dimension scales — this is what the app reads for its calibration.
writeDoubles(cube, "dim0", [0, scanStepA], units: "A")
writeDoubles(cube, "dim1", [0, scanStepA], units: "A")
writeDoubles(cube, "dim2", [0, diffStepMr], units: "mrad")
writeDoubles(cube, "dim3", [0, diffStepMr], units: "mrad")

// The answer, travelling with the data.
let truth = group(file, "truth")
writeStringAttribute(truth, "description",
                     "Aberrations planted in this dataset. tcBF should recover them.")
writeDoubles(truth, "defocus_C1", [defocusNm], units: "nm")
writeDoubles(truth, "astigmatism_A1", [astigNm], units: "nm")
writeDoubles(truth, "astigmatism_angle", [astigDegrees], units: "degrees")
writeDoubles(truth, "disc_radius", [discRadius], units: "detector pixels")
writeDoubles(truth, "disc_semiangle", [discRadius * diffStepMr], units: "mrad")
writeDoubles(truth, "edge_displacement", [k1 * discRadius], units: "scan pixels")
writeDoubles(truth, "third_order_edge_shift", [cubicEdgePx], units: "scan pixels")
writeDoubles(truth, "k_defocus", [k1], units: "scan px per detector px")
writeDoubles(truth, "k_astigmatism_a", [ka], units: "scan px per detector px")
writeDoubles(truth, "k_astigmatism_b", [kb], units: "scan px per detector px")

H5Gclose(truth)
H5Sclose(memorySpace); H5Dclose(data); H5Pclose(creation); H5Sclose(space)
H5Gclose(cube); H5Gclose(root); H5Fclose(file)

let size = (try! FileManager.default.attributesOfItem(atPath: outputPath)[.size] as! NSNumber).intValue
print(String(format: "\nwrote %@ (%.1f MB)", outputPath, Double(size) / 1e6))
print(String(format: "  defocus       %.1f nm   (edge displacement %.2f scan px)", defocusNm, k1 * discRadius))
print(String(format: "  astigmatism   %.1f nm at %.0f°", astigNm, astigDegrees))
print(String(format: "  third order   %.1f scan px at the disc edge", cubicEdgePx))
print(String(format: "  disc          %.0f detector px = %.0f mrad", discRadius, discRadius * diffStepMr))
print(String(format: "  calibration   %.2f A/scan px, %.2f mrad/detector px", scanStepA, diffStepMr))
