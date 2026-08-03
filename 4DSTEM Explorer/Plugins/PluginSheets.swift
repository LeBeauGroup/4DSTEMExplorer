//
//  PluginSheets.swift
//  4DSTEM Explorer
//
//  The parameter and progress sheets, and the panel plumbing that sizes them.
//
//  Deliberately free of any dependency on the rest of the app so the sizing
//  behaviour can be measured in isolation — getting a self-sizing sheet wrong
//  hides its own buttons, which is not something to find out by eye.
//
//  Copyright © 2017 The LeBeau Group. All rights reserved.
//

import Foundation
import SwiftUI
import AppKit

// MARK: - Parameters

struct PluginParameterDescriptor: Identifiable {
    let id: String
    let label: String
    let type: String
    let minimum: Double?
    let maximum: Double?
    let choices: [String]
    let help: String
    let defaultValue: Any

    /// Reads the descriptor dictionaries a plugin declared, dropping any that
    /// are unusable rather than failing the whole run.
    static func parse(_ dictionaries: [[String: Any]]) -> [PluginParameterDescriptor] {
        var seen = Set<String>()
        var result: [PluginParameterDescriptor] = []

        for dictionary in dictionaries {
            guard let id = dictionary[FDSParameterKey.identifier] as? String, !id.isEmpty else { continue }
            guard !seen.contains(id) else { continue }
            seen.insert(id)

            let type = dictionary[FDSParameterKey.type] as? String ?? FDSParameterType.number
            let choices = dictionary[FDSParameterKey.choices] as? [String] ?? []
            if type == FDSParameterType.choice && choices.isEmpty { continue }

            result.append(PluginParameterDescriptor(
                id: id,
                label: dictionary[FDSParameterKey.label] as? String ?? id,
                type: type,
                minimum: (dictionary[FDSParameterKey.minimum] as? NSNumber)?.doubleValue,
                maximum: (dictionary[FDSParameterKey.maximum] as? NSNumber)?.doubleValue,
                choices: choices,
                help: dictionary[FDSParameterKey.help] as? String ?? "",
                defaultValue: dictionary[FDSParameterKey.defaultValue] ?? NSNumber(value: 0)
            ))
        }
        return result
    }
}

final class PluginParameterStore: ObservableObject {

    let descriptors: [PluginParameterDescriptor]

    @Published var numbers: [String: Double] = [:]
    @Published var flags: [String: Bool] = [:]
    @Published var strings: [String: String] = [:]

    init(descriptors: [PluginParameterDescriptor]) {
        self.descriptors = descriptors
        for descriptor in descriptors {
            switch descriptor.type {
            case FDSParameterType.toggle:
                flags[descriptor.id] = (descriptor.defaultValue as? NSNumber)?.boolValue ?? false
            case FDSParameterType.choice:
                let fallback = descriptor.choices.first ?? ""
                let requested = descriptor.defaultValue as? String ?? fallback
                strings[descriptor.id] = descriptor.choices.contains(requested) ? requested : fallback
            case FDSParameterType.text:
                strings[descriptor.id] = descriptor.defaultValue as? String ?? ""
            default:
                numbers[descriptor.id] = clamp((descriptor.defaultValue as? NSNumber)?.doubleValue ?? 0, descriptor)
            }
        }
    }

    private func clamp(_ value: Double, _ descriptor: PluginParameterDescriptor) -> Double {
        var result = value
        if let minimum = descriptor.minimum { result = Swift.max(minimum, result) }
        if let maximum = descriptor.maximum { result = Swift.min(maximum, result) }
        return result
    }

    /// The values handed to `run(host:parameters:)`, typed as the plugin
    /// declared them so an `integer` parameter never arrives as a fractional
    /// double.
    func objectValues() -> [String: Any] {
        var result: [String: Any] = [:]
        for descriptor in descriptors {
            switch descriptor.type {
            case FDSParameterType.toggle:
                result[descriptor.id] = NSNumber(value: flags[descriptor.id] ?? false)
            case FDSParameterType.choice, FDSParameterType.text:
                result[descriptor.id] = strings[descriptor.id] ?? ""
            case FDSParameterType.integer:
                result[descriptor.id] = NSNumber(value: Int((numbers[descriptor.id] ?? 0).rounded()))
            default:
                result[descriptor.id] = NSNumber(value: numbers[descriptor.id] ?? 0)
            }
        }
        return result
    }

    /// Writes plugin-supplied values back into the controls, so a plugin that
    /// *measures* something can leave the control sitting at what it found.
    /// Returns true if any control actually moved.
    @discardableResult
    func apply(_ values: [String: Any]) -> Bool {
        var changed = false
        for descriptor in descriptors {
            guard let raw = values[descriptor.id] else { continue }
            switch descriptor.type {
            case FDSParameterType.toggle:
                if let value = (raw as? NSNumber)?.boolValue, flags[descriptor.id] != value {
                    flags[descriptor.id] = value
                    changed = true
                }
            case FDSParameterType.choice:
                if let value = raw as? String, descriptor.choices.contains(value), strings[descriptor.id] != value {
                    strings[descriptor.id] = value
                    changed = true
                }
            case FDSParameterType.text:
                if let value = raw as? String, strings[descriptor.id] != value {
                    strings[descriptor.id] = value
                    changed = true
                }
            default:
                if let value = (raw as? NSNumber)?.doubleValue, value.isFinite {
                    let clamped = clamp(value, descriptor)
                    if let existing = numbers[descriptor.id], abs(existing - clamped) < 1e-12 { continue }
                    numbers[descriptor.id] = clamped
                    changed = true
                }
            }
        }
        return changed
    }

    func binding(forNumber id: String) -> Binding<Double> {
        return Binding(get: { self.numbers[id] ?? 0 }, set: { self.numbers[id] = $0 })
    }

    func binding(forFlag id: String) -> Binding<Bool> {
        return Binding(get: { self.flags[id] ?? false }, set: { self.flags[id] = $0 })
    }

    func binding(forString id: String) -> Binding<String> {
        return Binding(get: { self.strings[id] ?? "" }, set: { self.strings[id] = $0 })
    }
}

// MARK: - Parameter controls

/// The controls a plugin declared, laid out. Shared by the modal sheet and the
/// live window so both stay in step.
struct PluginParameterControls: View {
    @ObservedObject var store: PluginParameterStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(store.descriptors) { descriptor in
                VStack(alignment: .leading, spacing: 3) {
                    control(for: descriptor)
                    if !descriptor.help.isEmpty {
                        Text(descriptor.help)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func control(for descriptor: PluginParameterDescriptor) -> some View {
        switch descriptor.type {
        case FDSParameterType.toggle:
            Toggle(descriptor.label, isOn: store.binding(forFlag: descriptor.id))

        case FDSParameterType.choice:
            Picker(descriptor.label, selection: store.binding(forString: descriptor.id)) {
                ForEach(descriptor.choices, id: \.self) { choice in
                    Text(choice).tag(choice)
                }
            }

        case FDSParameterType.text:
            HStack {
                Text(descriptor.label)
                TextField("", text: store.binding(forString: descriptor.id))
                    .textFieldStyle(.roundedBorder)
            }

        case FDSParameterType.integer:
            HStack {
                Text(descriptor.label)
                Spacer()
                TextField("", value: store.binding(forNumber: descriptor.id), format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                Stepper("", value: store.binding(forNumber: descriptor.id),
                        in: (descriptor.minimum ?? -1e9)...(descriptor.maximum ?? 1e9),
                        step: 1)
                    .labelsHidden()
            }

        default:
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(descriptor.label)
                    Spacer()
                    TextField("", value: store.binding(forNumber: descriptor.id), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                if let minimum = descriptor.minimum, let maximum = descriptor.maximum, maximum > minimum {
                    Slider(value: store.binding(forNumber: descriptor.id), in: minimum...maximum)
                }
            }
        }
    }
}

// MARK: - Parameter sheet

struct PluginParameterSheet: View {
    let pluginName: String
    let summary: String
    @ObservedObject var store: PluginParameterStore
    let onCancel: () -> Void
    let onRun: () -> Void

    var body: some View {
        // Summary and buttons take their natural height; the scroll view in the
        // middle absorbs whatever is left over. That ordering is what keeps the
        // buttons on screen no matter how the panel ends up being sized.
        VStack(alignment: .leading, spacing: 12) {
            if !summary.isEmpty {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                PluginParameterControls(store: store)
                    .padding(.trailing, 2)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Run", action: onRun)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}

// MARK: - Progress sheet

final class PluginProgressModel: ObservableObject {
    @Published var fraction: Double = 0
    @Published var note: String = ""
    let pluginName: String

    init(pluginName: String) {
        self.pluginName = pluginName
    }
}

struct PluginProgressSheet: View {
    @ObservedObject var model: PluginProgressModel
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Running \(model.pluginName)…")
                .font(.headline)
                .lineLimit(1)

            // A plugin that never calls reportProgress leaves the fraction at
            // zero, so show a barber pole rather than a bar stuck at empty.
            if model.fraction > 0 {
                ProgressView(value: model.fraction, total: 1.0)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            HStack {
                Text(model.note.isEmpty ? (model.fraction > 0 ? "\(Int(model.fraction * 100))%" : "Working…") : model.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
    }
}

// MARK: - Panel plumbing

/// Presents a SwiftUI view as a window-modal sheet sized to fit its content.
///
/// The caller fixes the width; the height is measured from the content and then
/// clamped. The panel's content view keeps `translatesAutoresizingMaskIntoConstraints`
/// on so the *window* drives the layout — with it off, nothing constrains the
/// height and a greedy child such as a scroll view expands the sheet until the
/// screen edge stops it, taking the buttons with it.
final class PluginSheetController {

    /// Set by the app so sheets attach to the main document window rather than
    /// whatever panel happens to be key. Optional, so this file stays testable.
    static var preferredHostWindowIdentifier: NSUserInterfaceItemIdentifier?

    /// Bounds for the measured height, in points.
    static let minimumHeight: CGFloat = 90
    static let defaultMaximumHeight: CGFloat = 620

    private var panel: NSPanel?

    /// The size the sheet will be given for this content and width. Split out
    /// from presentation so it can be checked without a window on screen.
    static func fittingSize<Content: View>(width: CGFloat,
                                           maximumHeight: CGFloat = defaultMaximumHeight,
                                           content: Content) -> NSSize {
        // Measure at the final width with the height unconstrained, so text
        // that wraps to an unexpected number of lines is accounted for.
        let probe = NSHostingView(rootView: content
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true))
        probe.layoutSubtreeIfNeeded()

        let measured = probe.fittingSize.height
        let usable = measured.isFinite && measured > 0 ? measured : maximumHeight
        let height = Swift.min(Swift.max(usable.rounded(.up), minimumHeight), maximumHeight)
        return NSSize(width: width, height: height)
    }

    func present<Content: View>(title: String,
                                width: CGFloat,
                                maximumHeight: CGFloat = defaultMaximumHeight,
                                @ViewBuilder content: () -> Content) {

        let view = content()
        let size = PluginSheetController.fittingSize(width: width, maximumHeight: maximumHeight, content: view)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.level = .modalPanel

        // A definite frame means the layout cannot overflow: the scroll view
        // takes the slack and the buttons stay put.
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        self.panel = panel

        if let host = PluginSheetController.hostWindow() {
            host.beginSheet(panel, completionHandler: nil)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func dismiss() {
        guard let panel = panel else { return }
        if let parent = panel.sheetParent {
            parent.endSheet(panel)
        }
        panel.orderOut(nil)
        panel.close()
        self.panel = nil
    }

    static func hostWindow() -> NSWindow? {
        func isContentWindow(_ window: NSWindow) -> Bool {
            return !(window is NSPanel) && window.isVisible && window.styleMask.contains(.titled)
        }
        if let identifier = preferredHostWindowIdentifier,
           let window = NSApp.windows.first(where: { $0.identifier == identifier && isContentWindow($0) }) {
            return window
        }
        let preferred = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
        if let window = preferred.first(where: isContentWindow) { return window }
        return NSApp.windows.first(where: isContentWindow)
    }
}
