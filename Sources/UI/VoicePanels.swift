// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit
import VoiceCore

// Gemeinsame Bausteine der Sprachmodule (D-Star, YSF, DMR)

/// Auswahl des Sprachsticks und Schalter für die Tonausgabe
struct VoiceStickSettings: View {
    @ObservedObject var output: VoiceOutput
    @State private var ports: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("STICK")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .frame(width: 56, alignment: .leading)
                Picker("", selection: $output.stickPort) {
                    Text("keiner").tag("")
                    ForEach(ports, id: \.self) { Text($0.replacingOccurrences(of: "/dev/cu.", with: "")).tag($0) }
                    if !output.stickPort.isEmpty, !ports.contains(output.stickPort) { Text(output.stickPort).tag(output.stickPort) }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                .help("Serieller Anschluss des Sprachsticks (DVSI AMBE-3000R, 460800 Baud). Es wird nur der gewählte Anschluss angesprochen: andere serielle Geräte (z. B. das CAT-Kabel des Funkgeräts) bekommen nichts.")
                Button("VERBINDEN") { output.connect() }
                    .buttonStyle(ModeButtonStyle(isSelected: output.decoderName != nil))
                    .lineLimit(1)
                    .fixedSize()
                    .help("Stick am gewählten Anschluss öffnen und prüfen")
                Button { ports = AMBE3000Stick.candidatePaths() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .help("Liste der seriellen Anschlüsse neu lesen")
            }
            HStack(spacing: 6) {
                Text("TON")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .frame(width: 56, alignment: .leading)
                Button("AUSGABE") { output.playAudio.toggle() }
                    .buttonStyle(ModeButtonStyle(isSelected: output.playAudio))
                    .lineLimit(1)
                    .fixedSize()
                    .help("Empfangene Sprache über den Standard-Ausgang abspielen (braucht einen Sprachdecoder)")
                Text(status)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(output.error != nil ? RadioTheme.ledRed : output.decoderName != nil ? RadioTheme.vfdGreen : RadioTheme.textMuted)
                    .lineLimit(2)
            }
        }
        .onAppear { ports = AMBE3000Stick.candidatePaths() }
    }

    private var status: String {
        if let e = output.error { return e }
        if let n = output.decoderName { return "Sprachdecoder: \(n)" }
        return "kein Sprachdecoder"
    }
}

/// Die laufende (oder zuletzt gehörte) Aussendung groß
struct VoiceCallNowCard: View {
    let call: VoiceCall?
    let locked: Bool
    let waiting: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let c = call {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle()
                        .fill(c.isLive ? RadioTheme.ledRed : RadioTheme.bgPanel)
                        .overlay(Circle().stroke(RadioTheme.borderSubtle, lineWidth: 1))
                        .frame(width: 10, height: 10)
                    Text(c.source.isEmpty ? "(Absender unbekannt)" : c.source)
                        .font(.system(size: 26, weight: .black, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdAmber)
                    Text(c.mode)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdCyan)
                    Spacer()
                    Text(String(format: "%.1f s", c.seconds))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(c.isLive ? RadioTheme.ledRed : RadioTheme.textMuted)
                }
                if !c.target.isEmpty || !c.via.isEmpty {
                    Text("→ \(c.target.isEmpty ? "—" : c.target)   über \(c.via.isEmpty ? "—" : c.via)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdGreen)
                }
                if !c.note.isEmpty {
                    Text(c.note)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textBright)
                        .lineLimit(2)
                }
                if c.lateEntry {
                    Text("Später Einstieg: der Kopf wurde nicht gehört")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                }
            } else {
                Text(locked ? "Aussendung wird empfangen …" : waiting)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RadioTheme.bgDeep)
        .cornerRadius(6)
    }
}

/// Verlauf der Aussendungen mit Wiedergabe
struct VoiceCallTable: View {
    let calls: [VoiceCall]
    let timeFormatter: DateFormatter
    let hasDecoder: Bool
    let replay: (VoiceCall) -> Void
    var targetTitle = "Ziel"
    var viaTitle = "Repeater"
    /// Ohne gespeicherte Sprachrahmen (M17 spielt direkt ab) entfällt die Wiedergabe-Spalte
    var replayAvailable = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                header
                ForEach(calls.reversed()) { c in row(c).id(c.id) }
            }
            .padding(6)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("UTC").frame(width: 56, alignment: .leading)
            Text("Absender").frame(width: 96, alignment: .leading)
            Text(targetTitle).frame(width: 96, alignment: .leading)
            Text(viaTitle).frame(width: 96, alignment: .leading)
            Text("Dauer").frame(width: 44, alignment: .trailing)
            Text("Hinweis").frame(maxWidth: .infinity, alignment: .leading)
            Text("").frame(width: 34)
            if replayAvailable { Text("").frame(width: 22) }
        }
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .foregroundColor(RadioTheme.textDim)
        .padding(.bottom, 3)
    }

    private func row(_ c: VoiceCall) -> some View {
        let color: Color = c.isLive ? RadioTheme.ledRed : c.source.isEmpty ? RadioTheme.textDim : RadioTheme.vfdGreen
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(timeFormatter.string(from: c.start)).frame(width: 56, alignment: .leading)
            Text(c.source.isEmpty ? "?" : c.source).frame(width: 96, alignment: .leading)
            Text(c.target).frame(width: 96, alignment: .leading)
            Text(c.via).frame(width: 96, alignment: .leading)
            Text(String(format: "%.1f", c.seconds)).frame(width: 44, alignment: .trailing)
            Text(c.note).frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
            QRZButton(text: c.source).frame(width: 34, alignment: .trailing)
            if replayAvailable {
                Button { replay(c) } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.plain)
                    .foregroundColor(hasDecoder ? RadioTheme.vfdCyan : RadioTheme.textDim)
                    .frame(width: 22)
                    .disabled(!hasDecoder || c.isLive || c.ambe.isEmpty)
                    .help(hasDecoder ? "Diese Aussendung noch einmal abspielen" : "Kein Sprachdecoder: Stick in den Einstellungen wählen")
            }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundColor(color)
        .help("\(c.mode) · \(c.frames) Sprachrahmen" + (c.endedBy == .lost ? " · Signal ohne Ende-Kennung abgebrochen" : "") + (c.lateEntry ? " · später Einstieg" : ""))
    }
}
