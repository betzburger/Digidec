// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

// MARK: - Universelles modales Dialogfenster im RadioTheme

public struct PresetModalSheet<Content: View>: View {
    public let title: String
    public let onSave: () -> Void
    public let onCancel: () -> Void
    public let isValid: Bool
    @ViewBuilder public let content: Content

    public init(title: String, isValid: Bool = true, onSave: @escaping () -> Void, onCancel: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.title = title
        self.isValid = isValid
        self.onSave = onSave
        self.onCancel = onCancel
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdCyan)
                Spacer()
                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
            }

            Divider().background(RadioTheme.borderSubtle)

            content

            Divider().background(RadioTheme.borderSubtle)

            HStack {
                Button(LocalizedStringKey("Abbrechen")) {
                    onCancel()
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(LocalizedStringKey("Speichern")) {
                    onSave()
                }
                .buttonStyle(ModeButtonStyle(isSelected: true))
                .disabled(!isValid)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 380)
        .background(RadioTheme.bgPanel)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Kontextmenü-Modifier für Preset-Buttons

public struct PresetContextMenuModifier: ViewModifier {
    public let onEdit: (() -> Void)?
    public let onDelete: (() -> Void)?
    public let onReset: (() -> Void)?

    public func body(content: Content) -> some View {
        content
            .contextMenu {
                if let onEdit {
                    Button {
                        onEdit()
                    } label: {
                        Label("Bearbeiten…", systemImage: "pencil")
                    }
                }
                if let onDelete {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("Löschen", systemImage: "trash")
                    }
                }
                if let onReset {
                    Divider()
                    Button {
                        onReset()
                    } label: {
                        Label("Auf Standard zurücksetzen", systemImage: "arrow.counterclockwise")
                    }
                }
            }
    }
}

public extension View {
    func presetContextMenu(onEdit: (() -> Void)? = nil, onDelete: (() -> Void)? = nil, onReset: (() -> Void)? = nil) -> some View {
        modifier(PresetContextMenuModifier(onEdit: onEdit, onDelete: onDelete, onReset: onReset))
    }
}

// MARK: - Editor für Frequenzen (RTTY, NAVTEX etc.)

public struct FrequencyItemEditor: View {
    @Binding public var label: String
    @Binding public var khzText: String
    @Binding public var callsign: String
    @Binding public var note: String

    public init(label: Binding<String>, khzText: Binding<String>, callsign: Binding<String>, note: Binding<String>) {
        self._label = label
        self._khzText = khzText
        self._callsign = callsign
        self._note = note
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldRow("Bezeichnung", text: $label, placeholder: "z. B. 14080 oder DDK 2")
            fieldRow("Frequenz (kHz)", text: $khzText, placeholder: "z. B. 14080,0 oder 147,3")
            fieldRow("Rufzeichen / Band", text: $callsign, placeholder: "z. B. 20m oder DDK 9")
            fieldRow("Notiz", text: $note, placeholder: "z. B. Tagbetrieb / US-Station")
        }
    }

    private func fieldRow(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
                .frame(width: 110, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
        }
    }
}

// MARK: - Editor für WEFAX-Stationen

public struct WefaxStationEditorView: View {
    @Binding public var label: String
    @Binding public var khzText: String
    @Binding public var note: String
    @Binding public var shiftHz: Int
    @Binding public var lpm: Int
    @Binding public var ioc: Int

    public init(label: Binding<String>, khzText: Binding<String>, note: Binding<String>, shiftHz: Binding<Int>, lpm: Binding<Int>, ioc: Binding<Int>) {
        self._label = label
        self._khzText = khzText
        self._note = note
        self._shiftHz = shiftHz
        self._lpm = lpm
        self._ioc = ioc
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldRow("Station / Label", text: $label, placeholder: "z. B. Boston NMF oder 7880")
            fieldRow("Frequenz (kHz)", text: $khzText, placeholder: "z. B. 6340,5 oder 7880,0")
            fieldRow("Notiz / QTH", text: $note, placeholder: "z. B. US Coast Guard Nacht")

            HStack(spacing: 8) {
                Text("Hub (Hz)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .frame(width: 110, alignment: .leading)
                ForEach([800, 850], id: \.self) { s in
                    Button("\(s) Hz") { shiftHz = s }
                        .buttonStyle(ModeButtonStyle(isSelected: shiftHz == s))
                }
            }

            HStack(spacing: 8) {
                Text("LPM (Zeilen/min)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .frame(width: 110, alignment: .leading)
                ForEach([60, 90, 120, 240], id: \.self) { l in
                    Button("\(l)") { lpm = l }
                        .buttonStyle(ModeButtonStyle(isSelected: lpm == l))
                }
            }

            HStack(spacing: 8) {
                Text("IOC-Modul")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .frame(width: 110, alignment: .leading)
                ForEach([576, 288], id: \.self) { v in
                    Button("\(v)") { ioc = v }
                        .buttonStyle(ModeButtonStyle(isSelected: ioc == v))
                }
            }
        }
    }

    private func fieldRow(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
                .frame(width: 110, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
        }
    }
}

// MARK: - Editor für RTTY-Presets

public struct RTTYPresetEditorView: View {
    @Binding public var name: String
    @Binding public var shiftText: String
    @Binding public var baudText: String
    @Binding public var bits: Int
    @Binding public var stopBits: Double
    @Binding public var reverse: Bool
    @Binding public var ita2: Bool
    @Binding public var unshiftOnSpace: Bool
    @Binding public var note: String

    public init(name: Binding<String>, shiftText: Binding<String>, baudText: Binding<String>, bits: Binding<Int>, stopBits: Binding<Double>, reverse: Binding<Bool>, ita2: Binding<Bool>, unshiftOnSpace: Binding<Bool>, note: Binding<String>) {
        self._name = name
        self._shiftText = shiftText
        self._baudText = baudText
        self._bits = bits
        self._stopBits = stopBits
        self._reverse = reverse
        self._ita2 = ita2
        self._unshiftOnSpace = unshiftOnSpace
        self._note = note
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldRow("Name", text: $name, placeholder: "z. B. Meteo France")
            fieldRow("Shift (Hz)", text: $shiftText, placeholder: "z. B. 170, 450 oder 850")
            fieldRow("Baudrate", text: $baudText, placeholder: "z. B. 45,45 oder 50")

            HStack(spacing: 8) {
                Text("Bits / Stopbits")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .frame(width: 110, alignment: .leading)
                ForEach([5, 7, 8], id: \.self) { b in
                    Button("\(b)b") { bits = b }
                        .buttonStyle(ModeButtonStyle(isSelected: bits == b))
                }
                ForEach([1.0, 1.5, 2.0], id: \.self) { s in
                    Button(s == 1.5 ? "1,5s" : "\(Int(s))s") { stopBits = s }
                        .buttonStyle(ModeButtonStyle(isSelected: stopBits == s))
                }
            }

            HStack(spacing: 8) {
                Text("Optionen")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .frame(width: 110, alignment: .leading)
                Button("REV") { reverse.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: reverse))
                    .help("Kehrlage (Mark tief)")
                Button("ITA2") { ita2.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: ita2))
                    .help("Europäischer Ziffernsatz")
                Button("UOS") { unshiftOnSpace.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: unshiftOnSpace))
                    .help("Unshift on Space (zurück zu Buchstaben nach Leerzeichen)")
            }

            fieldRow("Notiz", text: $note, placeholder: "z. B. Seewetterbericht Paris")
        }
    }

    private func fieldRow(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
                .frame(width: 110, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
        }
    }
}

// MARK: - Editor für SSTV-Kanäle

public struct SSTVChannelEditorView: View {
    @Binding public var shortLabel: String
    @Binding public var name: String
    @Binding public var mhzText: String
    @Binding public var modulation: String
    @Binding public var note: String

    public init(shortLabel: Binding<String>, name: Binding<String>, mhzText: Binding<String>, modulation: Binding<String>, note: Binding<String>) {
        self._shortLabel = shortLabel
        self._name = name
        self._mhzText = mhzText
        self._modulation = modulation
        self._note = note
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldRow("Kurzlabel", text: $shortLabel, placeholder: "z. B. 20m oder ISS")
            fieldRow("Name", text: $name, placeholder: "z. B. 20m (14,230 MHz USB)")
            fieldRow("Frequenz (MHz)", text: $mhzText, placeholder: "z. B. 14,230 oder 145,800 (leer = frei)")

            HStack(spacing: 8) {
                Text("Modulation")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .frame(width: 110, alignment: .leading)
                ForEach(["USB", "LSB", "FM"], id: \.self) { m in
                    Button(m) { modulation = m }
                        .buttonStyle(ModeButtonStyle(isSelected: modulation == m))
                }
            }

            fieldRow("Notiz", text: $note, placeholder: "z. B. Weltweiter SSTV-Hauptkanal")
        }
    }

    private func fieldRow(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
                .frame(width: 110, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
        }
    }
}

// MARK: - Einfacher Kanal-Editor (MHz oder kHz)

public struct SimpleChannelEditorView: View {
    public let unitTitle: String
    @Binding public var name: String
    @Binding public var freqText: String
    @Binding public var note: String

    public init(unitTitle: String = "Frequenz (MHz)", name: Binding<String>, freqText: Binding<String>, note: Binding<String>) {
        self.unitTitle = unitTitle
        self._name = name
        self._freqText = freqText
        self._note = note
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldRow("Bezeichnung", text: $name, placeholder: "z. B. DAPNET oder 145.010")
            fieldRow(unitTitle, text: $freqText, placeholder: "z. B. 439,9875 (leer = frei)")
            fieldRow("Notiz", text: $note, placeholder: "z. B. Winlink Node / Pagerkanal")
        }
    }

    private func fieldRow(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
                .frame(width: 110, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
        }
    }
}
