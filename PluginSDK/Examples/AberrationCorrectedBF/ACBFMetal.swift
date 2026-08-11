//
//  ACBFMetal.swift
//  4DSTEM Explorer — Aberration-Corrected Bright Field
//
//  GPU accumulation of the Fourier-domain sum.
//
//  Because the inverse transform is factored out (see ACBFReconstructor), the
//  entire inner loop is elementwise: for every scan frequency, walk the virtual
//  detectors and accumulate a weighted copy of each. One thread per scan
//  frequency, looping over detectors, gives perfectly coalesced reads — thread
//  i reads element b·pixels + i, so neighbouring threads touch neighbouring
//  addresses — and needs no atomics or threadgroup reduction.
//
//  The shader is compiled at run time from source. The offline Metal compiler
//  ships with Xcode rather than the command line tools, and compiling at run
//  time also means the bundle carries no .metallib to keep in step with the
//  Swift beside it.
//
//  Everything here is an optimisation. If Metal is unavailable, the device is
//  missing, or the shader fails to build, `accumulate` returns nil and the
//  caller falls through to the CPU path, which computes the same quantity in
//  double precision.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation
import Metal

// MARK: - Shader

private let acbfShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Term {
    int   radialPower;   // exponent of alpha^2 (always integral)
    int   m;             // azimuthal order
    float scaleX;        // coefficient * (2*pi/lambda) / (n+1), X component
    float scaleY;        // ditto, Y component (0 for m == 0)
};

struct Params {
    uint  rows;
    uint  columns;
    uint  detectors;
    uint  termCount;
    uint  maxM;
    uint  mode;          // 0 = tcBF, 1 = phase-only, 2 = complex inversion
    float wavelength;    // Angstrom
    float cutoff;        // aperture cutoff, radians
    float rolloff;       // aperture taper width, radians
    float epsilon;       // phase-only normalisation floor
};

static inline float acbf_aperture(float alpha, float cutoff, float rolloff) {
    if (rolloff <= 0.0f) { return alpha <= cutoff ? 1.0f : 0.0f; }
    if (alpha > cutoff) { return 0.0f; }
    if (alpha < cutoff - rolloff) { return 1.0f; }
    return 0.5f * (1.0f + cos(M_PI_F * (alpha - cutoff + rolloff) / rolloff));
}

// chi at one detector coordinate, in radians.
static inline float acbf_chi(float kx, float ky,
                             device const Term *terms, uint termCount,
                             uint maxM, float wavelength) {
    if (termCount == 0u) { return 0.0f; }

    float ax = kx * wavelength;
    float ay = ky * wavelength;
    float alphaSquared = ax * ax + ay * ay;

    // (ax + i*ay)^m, up to the largest m actually in use. Six covers every
    // order the host will build a term table for.
    float px[8];
    float py[8];
    px[0] = 1.0f; py[0] = 0.0f;
    uint limit = min(maxM, 7u);
    for (uint m = 0u; m < limit; ++m) {
        px[m + 1] = px[m] * ax - py[m] * ay;
        py[m + 1] = px[m] * ay + py[m] * ax;
    }

    float total = 0.0f;
    for (uint t = 0u; t < termCount; ++t) {
        Term term = terms[t];
        float radial = 1.0f;
        for (int r = 0; r < term.radialPower; ++r) { radial *= alphaSquared; }
        uint m = (uint)term.m;
        total += radial * (term.scaleX * px[m] + term.scaleY * py[m]);
    }
    return total;
}

kernel void acbf_accumulate(device const float *imageReal   [[buffer(0)]],
                            device const float *imageImag   [[buffer(1)]],
                            device const float *tiltX       [[buffer(2)]],
                            device const float *tiltY       [[buffer(3)]],
                            device const float *qx          [[buffer(4)]],
                            device const float *qy          [[buffer(5)]],
                            device const Term  *terms       [[buffer(6)]],
                            constant Params    &p           [[buffer(7)]],
                            device const float *shiftX      [[buffer(8)]],
                            device const float *shiftY      [[buffer(9)]],
                            device float       *outReal     [[buffer(10)]],
                            device float       *outImag     [[buffer(11)]],
                            device float       *outPower    [[buffer(12)]],
                            uint gid [[thread_position_in_grid]]) {

    uint pixels = p.rows * p.columns;
    if (gid >= pixels) { return; }

    float thisQx = qx[gid % p.columns];
    float thisQy = qy[gid / p.columns];

    float sumReal = 0.0f;
    float sumImag = 0.0f;
    float sumPower = 0.0f;

    for (uint b = 0u; b < p.detectors; ++b) {
        uint index = b * pixels + gid;
        float ir = imageReal[index];
        float ii = imageImag[index];

        float wr, wi;

        if (p.mode == 0u) {
            // tcBF: a pure translation, as a phase ramp.
            float phase = -2.0f * M_PI_F * (shiftX[b] * thisQx + shiftY[b] * thisQy);
            wr = cos(phase);
            wi = sin(phase);
        } else {
            float kxt = tiltX[b];
            float kyt = tiltY[b];

            float plusX = thisQx + kxt,  plusY = thisQy + kyt;
            float minusX = thisQx - kxt, minusY = thisQy - kyt;

            float apPlus = acbf_aperture(sqrt(plusX * plusX + plusY * plusY) * p.wavelength,
                                         p.cutoff, p.rolloff);
            float apMinus = acbf_aperture(sqrt(minusX * minusX + minusY * minusY) * p.wavelength,
                                          p.cutoff, p.rolloff);

            if (apPlus == 0.0f && apMinus == 0.0f) { continue; }

            float chiTilt = acbf_chi(kxt, kyt, terms, p.termCount, p.maxM, p.wavelength);
            float chiPlus = apPlus == 0.0f ? 0.0f
                : acbf_chi(plusX, plusY, terms, p.termCount, p.maxM, p.wavelength);
            float chiMinus = apMinus == 0.0f ? 0.0f
                : acbf_chi(-minusX, -minusY, terms, p.termCount, p.maxM, p.wavelength);

            float phaseMinus = -(chiTilt - chiMinus);
            float phasePlus = chiTilt - chiPlus;

            float dReal = apMinus * cos(phaseMinus) - apPlus * cos(phasePlus);
            float dImag = apMinus * sin(phaseMinus) - apPlus * sin(phasePlus);

            // T = -i * D
            float tr = dImag;
            float ti = -dReal;

            if (p.mode == 2u) {
                sumReal += tr * ir - ti * ii;
                sumImag += tr * ii + ti * ir;
                sumPower += tr * tr + ti * ti;
                continue;
            }

            float magnitude = sqrt(tr * tr + ti * ti);
            float scale = 1.0f / (magnitude + p.epsilon);
            wr = tr * scale;
            wi = ti * scale;
        }

        sumReal += ir * wr - ii * wi;
        sumImag += ir * wi + ii * wr;
    }

    outReal[gid] = sumReal;
    outImag[gid] = sumImag;
    if (p.mode == 2u) { outPower[gid] = sumPower; }
}
"""

// MARK: - Host side

/// Mirrors the `Term` struct in the shader.
private struct ACBFShaderTerm {
    var radialPower: Int32
    var m: Int32
    var scaleX: Float
    var scaleY: Float
}

/// Mirrors `Params`.
private struct ACBFShaderParams {
    var rows: UInt32
    var columns: UInt32
    var detectors: UInt32
    var termCount: UInt32
    var maxM: UInt32
    var mode: UInt32
    var wavelength: Float
    var cutoff: Float
    var rolloff: Float
    var epsilon: Float
}

/// Runs the accumulation on the GPU. Created once and reused; building the
/// pipeline costs tens of milliseconds, and uploading the image stack costs
/// more, so both are cached across reconstructions.
final class ACBFMetalAccumulator {

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    /// The uploaded stack, keyed so a changed stack is noticed.
    private var stackToken: ObjectIdentifier?
    private var imageReal: MTLBuffer?
    private var imageImaginary: MTLBuffer?

    private(set) var deviceName: String

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: acbfShaderSource, options: nil)
            guard let function = library.makeFunction(name: "acbf_accumulate") else { return nil }
            self.pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            NSLog("[acBF] Metal shader unavailable, falling back to CPU: %@",
                  error.localizedDescription)
            return nil
        }
        self.device = device
        self.queue = queue
        self.deviceName = device.name
    }

    /// Uploads the stack if it is not the one already resident.
    private func upload(stack: ACBFStack) -> Bool {
        let token = ObjectIdentifier(stack)
        if stackToken == token, imageReal != nil, imageImaginary != nil { return true }

        let bytes = stack.count * stack.pixelCount * MemoryLayout<Float>.stride
        guard bytes > 0,
              let real = stack.realBuffer(device: device),
              let imaginary = stack.imaginaryBuffer(device: device) else { return false }
        imageReal = real
        imageImaginary = imaginary
        stackToken = token
        return true
    }

    /// Returns nil when the GPU cannot service this request, which tells the
    /// caller to use the CPU path rather than to give up.
    func accumulate(stack: ACBFStack,
                    coefficients: [Double],
                    mode: ACBFMode,
                    optics: ACBFOptics,
                    orders: ACBFOrders,
                    epsilon: Double,
                    qx: [Double],
                    qy: [Double]) -> ACBFAccumulation? {

        guard upload(stack: stack) else { return nil }

        let pixels = stack.pixelCount
        let modeCode: UInt32
        switch mode {
        case .tcBF: modeCode = 0
        case .acBFPhaseOnly: modeCode = 1
        case .acBFComplexInversion: modeCode = 2
        }

        // Term table: the same folding the CPU evaluator does, so the two agree
        // term for term.
        var terms: [ACBFShaderTerm] = []
        var maxM = 0
        let multiplier = 2 * Double.pi / optics.wavelength
        for key in orders.keys {
            let inverse = multiplier / Double(key.n + 1)
            let x = coefficients[key.offset] * inverse
            let y = key.width == 2 ? coefficients[key.offset + 1] * inverse : 0
            if x == 0 && y == 0 { continue }
            terms.append(ACBFShaderTerm(radialPower: Int32((key.n + 1 - key.m) / 2),
                                        m: Int32(key.m),
                                        scaleX: Float(x), scaleY: Float(y)))
            maxM = Swift.max(maxM, key.m)
        }
        // The shader's power tables are eight deep.
        guard maxM <= 7 else { return nil }

        // tcBF shifts are cheap on the CPU and only Nb of them, so they are
        // computed here rather than rebuilding the shift basis in the shader.
        var shiftX = [Float](repeating: 0, count: stack.count)
        var shiftY = [Float](repeating: 0, count: stack.count)
        if modeCode == 0 {
            let function = ACBFAberrationFunction(orders: orders, wavelength: optics.wavelength)
            for b in 0..<stack.count {
                let s = function.shift(kx: stack.tiltX[b], ky: stack.tiltY[b],
                                       coefficients: coefficients)
                shiftX[b] = Float(s.dx)
                shiftY[b] = Float(s.dy)
            }
        }

        var params = ACBFShaderParams(
            rows: UInt32(stack.rows), columns: UInt32(stack.columns),
            detectors: UInt32(stack.count), termCount: UInt32(terms.count),
            maxM: UInt32(maxM), mode: modeCode,
            wavelength: Float(optics.wavelength),
            cutoff: Float(optics.maxAlpha / 1000),
            rolloff: Float(optics.rolloff / 1000),
            epsilon: Float(epsilon))

        let tiltX = stack.tiltX.map { Float($0) }
        let tiltY = stack.tiltY.map { Float($0) }
        let qxF = qx.map { Float($0) }
        let qyF = qy.map { Float($0) }

        // A zero-length buffer is invalid, so empty inputs get one element.
        func buffer<T>(_ array: [T]) -> MTLBuffer? {
            let source = array.isEmpty ? [T](repeating: array.first ?? unsafeBitCast(0, to: T.self), count: 0) : array
            if source.isEmpty {
                return device.makeBuffer(length: MemoryLayout<T>.stride, options: .storageModeShared)
            }
            return device.makeBuffer(bytes: source, length: source.count * MemoryLayout<T>.stride,
                                     options: .storageModeShared)
        }

        guard let tiltXBuffer = buffer(tiltX), let tiltYBuffer = buffer(tiltY),
              let qxBuffer = buffer(qxF), let qyBuffer = buffer(qyF),
              let shiftXBuffer = buffer(shiftX), let shiftYBuffer = buffer(shiftY),
              let outReal = device.makeBuffer(length: pixels * MemoryLayout<Float>.stride,
                                              options: .storageModeShared),
              let outImaginary = device.makeBuffer(length: pixels * MemoryLayout<Float>.stride,
                                                   options: .storageModeShared),
              let outPower = device.makeBuffer(length: pixels * MemoryLayout<Float>.stride,
                                               options: .storageModeShared)
        else { return nil }

        let termBuffer: MTLBuffer
        if terms.isEmpty {
            guard let empty = device.makeBuffer(length: MemoryLayout<ACBFShaderTerm>.stride,
                                                options: .storageModeShared) else { return nil }
            termBuffer = empty
        } else {
            guard let filled = device.makeBuffer(bytes: terms,
                                                 length: terms.count * MemoryLayout<ACBFShaderTerm>.stride,
                                                 options: .storageModeShared) else { return nil }
            termBuffer = filled
        }

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(imageReal, offset: 0, index: 0)
        encoder.setBuffer(imageImaginary, offset: 0, index: 1)
        encoder.setBuffer(tiltXBuffer, offset: 0, index: 2)
        encoder.setBuffer(tiltYBuffer, offset: 0, index: 3)
        encoder.setBuffer(qxBuffer, offset: 0, index: 4)
        encoder.setBuffer(qyBuffer, offset: 0, index: 5)
        encoder.setBuffer(termBuffer, offset: 0, index: 6)
        encoder.setBytes(&params, length: MemoryLayout<ACBFShaderParams>.stride, index: 7)
        encoder.setBuffer(shiftXBuffer, offset: 0, index: 8)
        encoder.setBuffer(shiftYBuffer, offset: 0, index: 9)
        encoder.setBuffer(outReal, offset: 0, index: 10)
        encoder.setBuffer(outImaginary, offset: 0, index: 11)
        encoder.setBuffer(outPower, offset: 0, index: 12)

        let width = Swift.min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        encoder.dispatchThreads(MTLSize(width: pixels, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if commandBuffer.status != .completed { return nil }

        func read(_ buffer: MTLBuffer) -> [Float] {
            let pointer = buffer.contents().bindMemory(to: Float.self, capacity: pixels)
            return Array(UnsafeBufferPointer(start: pointer, count: pixels))
        }

        return ACBFAccumulation(real: read(outReal),
                                imaginary: read(outImaginary),
                                power: modeCode == 2 ? read(outPower) : nil)
    }
}

// MARK: - Buffer bridging

extension ACBFStack {
    func realBuffer(device: MTLDevice) -> MTLBuffer? {
        return real.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
        }
    }

    func imaginaryBuffer(device: MTLDevice) -> MTLBuffer? {
        return imaginary.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
        }
    }
}
