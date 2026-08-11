import AppKit
import Quartz

// Assumes a Matrix type exists in the project with methods:
// - floatImageRep() -> NSBitmapImageRep?
// - Optional: .log()
// If your Matrix API differs, adapt the conversion in bitmap(from:) accordingly.

enum MatrixExportError: Error {
    case noBitmap
    case cannotCreateDestination
    case writeFailed
}

struct MatrixExporting {
    static func bitmap(from matrix: Matrix) -> NSBitmapImageRep? {
        // Reuse your existing floatImageRep() helper if available
        return matrix.floatImageRep()
    }

    static func writeTIFF(matrix: Matrix, to url: URL, tiffDescription: String? = nil) throws {
        guard let rep = bitmap(from: matrix), let cgImage = rep.cgImage else {
            throw MatrixExportError.noBitmap
        }

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, kUTTypeTIFF, 1, nil) else {
            throw MatrixExportError.cannotCreateDestination
        }

        var props: [CFString: Any] = [:]
        if let desc = tiffDescription {
            props["{TIFF}" as CFString] = ["ImageDescription" as CFString: desc]
        }

        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        if !CGImageDestinationFinalize(dest) {
            throw MatrixExportError.writeFailed
        }
    }
}
