//
//  HistogramRangeControl.swift
//
//  A self-contained display-range tool: a log-count histogram of some values
//  with two draggable handles that set the black and white points. It has no
//  dependencies on the rest of the app, so it can move into a shared package
//  as is.
//

import SwiftUI
import Accelerate

struct HistogramRangeControl: View {
    /// Produces the data being displayed. Called off the render path, only
    /// when `sourceID` changes.
    let source: () -> [Float]
    /// Changes whenever the data does.
    let sourceID: AnyHashable
    /// Percentiles the automatic range uses; nil means min to max.
    var autoQuantiles: ClosedRange<Float>? = nil
    /// nil = automatic.
    @Binding var range: ClosedRange<Float>?
    var binCount = 128

    @State private var bins: [Float] = []
    @State private var autoRange: ClosedRange<Float>?
    @State private var axis: ClosedRange<Float> = 0...1
    @State private var dragStartRange: ClosedRange<Float>?

    private var shown: ClosedRange<Float> { range ?? autoRange ?? axis }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                let span = max(axis.upperBound - axis.lowerBound, .leastNonzeroMagnitude)
                let lo = CGFloat((shown.lowerBound - axis.lowerBound) / span)
                let hi = CGFloat((shown.upperBound - axis.lowerBound) / span)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .controlBackgroundColor))
                    BinsShape(bins: bins).fill(Color.secondary.opacity(0.35))
                    BinsShape(bins: bins).fill(Color.accentColor)
                        .clipShape(Rectangle().path(in: CGRect(x: min(max(lo, 0), 1) * w, y: 0,
                                                              width: max(min(max(hi, 0), 1) - min(max(lo, 0), 1), 0) * w,
                                                              height: geo.size.height)))
                    handle(at: lo, width: w, height: geo.size.height, isLow: true, span: span)
                    handle(at: hi, width: w, height: geo.size.height, isLow: false, span: span)
                }
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            }
            .frame(height: 64)

            HStack(spacing: 6) {
                Text(format(shown.lowerBound)).monospacedDigit()
                Spacer()
                Button("Auto") { range = nil }
                    .controlSize(.small)
                    .disabled(range == nil)
                Spacer()
                Text(format(shown.upperBound)).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .task(id: sourceID) {
            let v = source(), n = binCount, q = autoQuantiles
            let result = await Task.detached(priority: .userInitiated) { Self.bin(v, count: n, quantiles: q) }.value
            bins = result.bins
            axis = result.axis
            autoRange = result.auto
        }
    }

    private func handle(at fraction: CGFloat, width: CGFloat, height: CGFloat,
                        isLow: Bool, span: Float) -> some View {
        let x = min(max(fraction, 0), 1) * width
        return Rectangle()
            .fill(Color.accentColor)
            .frame(width: 2, height: height)
            .overlay(Color.clear.frame(width: 14, height: height).contentShape(Rectangle()))
            .offset(x: x - 1)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if dragStartRange == nil { dragStartRange = shown }
                    guard let start = dragStartRange, width > 0 else { return }
                    let delta = Float(drag.translation.width / width) * span
                    var lo = start.lowerBound, hi = start.upperBound
                    let minGap = span / 1000
                    if isLow {
                        lo = min(max(lo + delta, axis.lowerBound), hi - minGap)
                    } else {
                        hi = max(min(hi + delta, axis.upperBound), lo + minGap)
                    }
                    range = lo...hi
                }
                .onEnded { _ in dragStartRange = nil })
    }

    private func format(_ v: Float) -> String { String(format: "%.4g", Double(v)) }

    nonisolated private static func bin(_ values: [Float], count: Int, quantiles q: ClosedRange<Float>?)
        -> (bins: [Float], axis: ClosedRange<Float>, auto: ClosedRange<Float>?) {
        var lo = Float.infinity, hi = -Float.infinity
        for v in values where v.isFinite { lo = min(lo, v); hi = max(hi, v) }
        guard lo.isFinite, hi > lo else { return ([], 0...1, nil) }
        var auto: ClosedRange<Float> = lo...hi
        if let q {
            let sorted = values.filter { $0.isFinite }.sorted()
            let at = { (p: Float) in sorted[min(sorted.count - 1, Int(p * Float(sorted.count - 1)))] }
            let l = at(q.lowerBound), h = at(q.upperBound)
            auto = l...max(h, l)
        }
        var counts = [Float](repeating: 0, count: count)
        let scale = Float(count - 1) / (hi - lo)
        for v in values where v.isFinite {
            counts[Int(min(max((v - lo) * scale, 0), Float(count - 1)))] += 1
        }
        var out = counts
        var n = Int32(count)
        vvlog1pf(&out, counts, &n)
        return (out, lo...hi, auto)
    }
}

private struct BinsShape: Shape {
    let bins: [Float]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard bins.count > 1, let peak = bins.max(), peak > 0 else { return path }
        let step = rect.width / CGFloat(bins.count - 1)
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for (i, value) in bins.enumerated() {
            path.addLine(to: CGPoint(x: rect.minX + CGFloat(i) * step,
                                     y: rect.maxY - CGFloat(value / peak) * rect.height))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
