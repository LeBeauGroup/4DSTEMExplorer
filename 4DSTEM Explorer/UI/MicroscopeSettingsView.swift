//
//  MicroscopeSettingsView.swift
//  4DSTEM Explorer
//
//  Editing what the application knows about the instruments it is used with.
//
//  Laid out the way the data is shaped. On the left, the things that belong to
//  the microscope: the instrument itself, and the detectors fitted to it. On the
//  right, the things that depend on how it is being run: a voltage, and for the
//  selected detector at that voltage, what one electron reads as and what angle
//  a pixel subtends at each camera length.
//
//  So a detector is described once however many voltages it is used at, and its
//  settings are described once per voltage — which is the only part that
//  actually changes with the beam energy.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import SwiftUI

struct MicroscopeSettingsView: View {

    @ObservedObject private var library = MicroscopeLibrary.shared

    @State private var microscopeID: MicroscopeProfile.ID?
    @State private var detectorID: DetectorProfile.ID?
    @State private var voltageID: VoltageProfile.ID?

    // MARK: Paths

    private var m: Int? {
        guard let id = microscopeID else { return nil }
        return library.microscopes.firstIndex { $0.id == id }
    }
    private var v: Int? {
        guard let m = m, let id = voltageID else { return nil }
        return library.microscopes[m].voltages.firstIndex { $0.id == id }
    }
    private var detectors: [DetectorProfile] { m.map { library.microscopes[$0].detectors } ?? [] }
    private var voltages: [VoltageProfile] { m.map { library.microscopes[$0].voltages } ?? [] }

    var body: some View {
        HSplitView {
            hardware.frame(minWidth: 230, idealWidth: 250)
            settings.frame(minWidth: 400)
        }
        .frame(minWidth: 700, minHeight: 520)
        .onAppear {
            if microscopeID == nil { microscopeID = library.microscopes.first?.id }
            if detectorID == nil { detectorID = detectors.first?.id }
            if voltageID == nil { voltageID = voltages.first?.id }
        }
    }

    // MARK: Left — the instrument and its detectors

    private var hardware: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Microscopes").font(.headline).padding([.horizontal, .top], 10)
            List(selection: $microscopeID) {
                ForEach(library.microscopes) { scope in
                    Text(scope.name.isEmpty ? "Untitled" : scope.name)
                        .tag(scope.id as MicroscopeProfile.ID?)
                }
            }
            .onChange(of: microscopeID) { _, _ in
                detectorID = detectors.first?.id
                voltageID = voltages.first?.id
            }
            buttons(add: addMicroscope, remove: removeMicroscope, enabled: m != nil)

            Divider()

            Text("Detectors fitted").font(.headline).padding([.horizontal, .top], 10)
            Text("Described once; their settings are per voltage.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
            if m == nil {
                hint("Choose or add a microscope.")
                Spacer()
            } else {
                List(selection: $detectorID) {
                    ForEach(detectors) { detector in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(detector.name.isEmpty ? "Untitled" : detector.name)
                            if let pitch = detector.pixelPitchMicrometres {
                                Text(String(format: "%.4g µm pixels", pitch))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(detector.id as DetectorProfile.ID?)
                    }
                }
                buttons(add: addDetector, remove: removeDetector, enabled: detectorID != nil)
            }
        }
    }

    // MARK: Right — voltage-dependent settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let m = m {
                HStack {
                    Text("Microscope").frame(width: 90, alignment: .leading)
                    TextField("Name", text: Binding(get: { library.microscopes[m].name },
                                                    set: { library.microscopes[m].name = $0 }))
                }
                if let index = detectorIndex {
                    HStack {
                        Text("Detector").frame(width: 90, alignment: .leading)
                        TextField("Name", text: Binding(
                            get: { library.microscopes[m].detectors[index].name },
                            set: { library.microscopes[m].detectors[index].name = $0 }))
                    }
                    HStack {
                        Text("Pixel pitch").frame(width: 90, alignment: .leading)
                        TextField("unknown", value: Binding(
                            get: { library.microscopes[m].detectors[index].pixelPitchMicrometres },
                            set: { library.microscopes[m].detectors[index].pixelPitchMicrometres = $0 }),
                                  format: .number.grouping(.never)).frame(width: 110)
                        Text("µm — a property of the sensor, the same at every voltage")
                            .font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                Divider()
                voltagePicker
                Divider()
            } else {
                hint("Choose or add a microscope.")
            }

            if m != nil, detectorIndex != nil, v != nil {
                perVoltage
            } else if m != nil {
                hint("Select a detector and a voltage to record its settings.")
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private var detectorIndex: Int? {
        guard let m = m, let id = detectorID else { return nil }
        return library.microscopes[m].detectors.firstIndex { $0.id == id }
    }

    private var voltagePicker: some View {
        HStack {
            Text("Voltage").frame(width: 90, alignment: .leading)
            if voltages.isEmpty {
                Text("none yet").foregroundStyle(.secondary)
            } else {
                Picker("", selection: $voltageID) {
                    ForEach(voltages) { Text($0.label).tag($0.id as VoltageProfile.ID?) }
                }
                .labelsHidden().frame(width: 120)
            }
            if let m = m, let v = v {
                TextField("kV", value: Binding(
                    get: { library.microscopes[m].voltages[v].kilovolts },
                    set: { library.microscopes[m].voltages[v].kilovolts = $0 }),
                          format: .number.grouping(.never)).frame(width: 70)
                Text("kV").foregroundStyle(.secondary)
            }
            Button(action: addVoltage) { Image(systemName: "plus") }
            Button(action: removeVoltage) { Image(systemName: "minus") }.disabled(v == nil)
            Spacer()
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private var perVoltage: some View {
        if let m = m, let v = v, let d = detectorIndex {
            let detector = library.microscopes[m].detectors[d]
            let c = library.ensureCalibration(microscope: m, voltage: v, detector: detector.id)
            let reading = Binding(
                get: { library.microscopes[m].voltages[v].calibrations[c] },
                set: { library.microscopes[m].voltages[v].calibrations[c] = $0 })

            Text("\(detector.name) at \(library.microscopes[m].voltages[v].label)")
                .font(.headline)

            HStack {
                Text("ADU").frame(width: 90, alignment: .leading)
                TextField("unknown", value: reading.countsPerElectron,
                          format: .number.grouping(.never)).frame(width: 110)
                Text("counts per electron").font(.footnote).foregroundStyle(.secondary)
            }

            Text("Camera lengths").font(.headline).padding(.top, 4)
            Text("The angle a detector pixel subtends at each camera length. Between two entries the step follows the geometry — it falls as the reciprocal of the length — and one entry is enough to scale to any other.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Nominal (mm)").frame(width: 110, alignment: .leading)
                Text("mrad / pixel").frame(width: 110, alignment: .leading)
                Text("Note")
            }
            .font(.caption).foregroundStyle(.secondary)

            List {
                ForEach(reading.cameraLengths) { $entry in
                    HStack {
                        TextField("mm", value: $entry.nominalMillimetres,
                                  format: .number.grouping(.never)).frame(width: 110)
                        TextField("mrad/px", value: $entry.diffractionStepMilliradians,
                                  format: .number.grouping(.never)).frame(width: 110)
                        TextField("note", text: $entry.note)
                    }
                }
                .onDelete { reading.wrappedValue.cameraLengths.remove(atOffsets: $0) }
            }
            .frame(minHeight: 120)

            HStack {
                Button {
                    reading.wrappedValue.cameraLengths.append(
                        CameraLengthCalibration(nominalMillimetres: 0,
                                                diffractionStepMilliradians: 0))
                } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                Text("Select a row and press delete to remove it.")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    // MARK: Pieces

    private func hint(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.top, 4)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func buttons(add: @escaping () -> Void, remove: @escaping () -> Void,
                         enabled: Bool) -> some View {
        HStack(spacing: 4) {
            Button(action: add) { Image(systemName: "plus") }
            Button(action: remove) { Image(systemName: "minus") }.disabled(!enabled)
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.bottom, 6)
    }

    // MARK: Editing

    private func addMicroscope() {
        var scope = MicroscopeProfile(name: "New microscope")
        scope.voltages = [VoltageProfile(kilovolts: 200)]
        library.microscopes.append(scope)
        microscopeID = scope.id
        detectorID = nil
        voltageID = scope.voltages.first?.id
    }

    private func removeMicroscope() {
        guard let m = m else { return }
        library.microscopes.remove(at: m)
        microscopeID = library.microscopes.first?.id
        detectorID = detectors.first?.id
        voltageID = voltages.first?.id
    }

    private func addDetector() {
        guard let m = m else { return }
        let next = DetectorProfile(name: "New detector")
        library.microscopes[m].detectors.append(next)
        detectorID = next.id
    }

    private func removeDetector() {
        guard let m = m, let id = detectorID else { return }
        // The readings at every voltage referred to this detector; without them
        // going too they would linger, pointing at nothing.
        library.forgetCalibrations(microscope: m, detector: id)
        library.microscopes[m].detectors.removeAll { $0.id == id }
        detectorID = library.microscopes[m].detectors.first?.id
    }

    private func addVoltage() {
        guard let m = m else { return }
        let next = VoltageProfile(kilovolts: library.microscopes[m].voltages.last?.kilovolts ?? 200)
        library.microscopes[m].voltages.append(next)
        voltageID = next.id
    }

    private func removeVoltage() {
        guard let m = m, let v = v else { return }
        library.microscopes[m].voltages.remove(at: v)
        voltageID = library.microscopes[m].voltages.first?.id
    }
}
