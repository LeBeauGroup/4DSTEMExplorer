//
//  ArinaOptionsSheet.swift
//  4DSTEM Explorer
//
//  Asked before an ARINA scan is read, because two things have to be decided
//  that the file cannot answer.
//
//  The raster: the detector records how many frames it was triggered for and
//  nothing about their arrangement, so a square scan is offered and the user
//  corrects it if it was not one.
//
//  The reduction: a full scan is far larger than memory. A 1024×1024 raster of
//  96×96 frames is 39 GB once converted to the float the rest of the
//  application works in, so it is reduced on the way in — and since that
//  discards something either way, it is a choice rather than a default applied
//  quietly. The cost is shown in the units that matter: how much memory it will
//  take, and how long it will take to get there.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import SwiftUI

struct ArinaOptionsSheet: View {

    let fileHint: String
    let frameCount: Int
    let patternWidth: Int
    let patternHeight: Int
    /// The square raster the frame count implies, used to seed the field.
    let suggestedSide: Int

    @State var rasterText: String
    @State var factor: Int = 8
    // Stride by default: it is the quick look, costing a fraction of the
    // frames and so a fraction of the wait. Binning keeps every electron and
    // is the one to reach for once the scan is worth the minutes.
    @State var reduction: ArinaReduction = .stride

    let onCancel: () -> Void
    let onOK: (_ width: Int, _ height: Int, _ factor: Int, _ reduction: ArinaReduction) -> Void

    private static let factors = [1, 2, 4, 8, 16, 32]

    // MARK: Derived

    private var raster: (width: Int, height: Int)? {
        let cleaned = rasterText.lowercased()
            .replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: "*", with: "x")
        let parts = cleaned.split(whereSeparator: { $0 == "x" || $0 == " " })
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return (parts[0], parts[1])
    }

    private var output: (width: Int, height: Int)? {
        guard let raster = raster else { return nil }
        return (max(1, raster.width / factor), max(1, raster.height / factor))
    }

    private var memoryBytes: Int {
        guard let out = output else { return 0 }
        return out.width * out.height * patternWidth * patternHeight * MemoryLayout<Float>.size
    }

    /// Frames that actually have to be decoded, which is what the wait is made
    /// of — striding skips the rest without touching them.
    private var framesDecoded: Int {
        guard let raster = raster, let out = output else { return 0 }
        return reduction == .bin ? raster.width * raster.height : out.width * out.height
    }

    /// About 55 µs a frame on one core — measured end to end against the real
    /// files, not from the decoder alone, which is nearer 35 and would make the
    /// estimate flattering by a third.
    private var estimatedSeconds: Double { return Double(framesDecoded) * 55e-6 }

    private var rasterProblem: String? {
        guard let raster = raster else { return "Give the raster as width × height." }
        let positions = raster.width * raster.height
        if positions > frameCount {
            return "That is \(positions.formatted()) positions, but the detector wrote \(frameCount.formatted()) frames."
        }
        if positions < frameCount {
            return "That accounts for \(positions.formatted()) of \(frameCount.formatted()) frames; the rest will be ignored."
        }
        return nil
    }

    private var rasterIsFatal: Bool {
        guard let raster = raster else { return true }
        return raster.width * raster.height > frameCount
    }

    private func formatted(bytes: Int) -> String {
        let gb = Double(bytes) / 1e9
        return gb >= 1 ? String(format: "%.2f GB", gb) : String(format: "%.0f MB", Double(bytes) / 1e6)
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Open ARINA Scan").font(.headline)
                Text(fileHint).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text("\(frameCount.formatted()) frames of \(patternWidth)×\(patternHeight)")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Scan raster").frame(width: 110, alignment: .leading)
                    TextField("1024 x 1024", text: $rasterText).frame(width: 130)
                    Text(suggestedSide * suggestedSide == frameCount
                         ? "square, from the frame count" : "the file does not record it")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Reduce by").frame(width: 110, alignment: .leading)
                    Picker("", selection: $factor) {
                        ForEach(Self.factors, id: \.self) { Text($0 == 1 ? "none" : "\($0)×").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    if let out = output {
                        Text("→ \(out.width) × \(out.height) positions")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Method").frame(width: 110, alignment: .leading)
                    Picker("", selection: $reduction) {
                        ForEach(ArinaReduction.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                    .disabled(factor == 1)
                }
            }

            Text(factor == 1 ? "Every probe position is kept." : reduction.explanation)
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: 44, alignment: .top)

            Divider()

            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatted(bytes: memoryBytes))
                        .font(.title3).monospacedDigit()
                    Text("in memory once loaded")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(estimatedSeconds < 1
                         ? "under a second"
                         : String(format: "about %.0f s", estimatedSeconds))
                        .font(.title3).monospacedDigit()
                    Text("\(framesDecoded.formatted()) frames decoded")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let problem = rasterProblem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(rasterIsFatal ? .red : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Open") {
                    guard let raster = raster, !rasterIsFatal else { NSSound.beep(); return }
                    onOK(raster.width, raster.height, factor, reduction)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(rasterIsFatal)
            }
        }
        .padding(18)
        .frame(width: 520)
    }
}
