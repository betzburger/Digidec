// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI

// MARK: - Umschalter Abstimmanzeige ↔ S-Meter

/// Die Karte „Abstimmanzeige“: zeigt entweder die Anzeige des Moduls oder das analoge S-Meter des SDR-Empfängers.
/// Die Wahl gilt für alle Module und bleibt gespeichert.
struct TuningDisplayCard<Content: View>: View {
    let content: Content
    @ObservedObject var controller: SDRController
    @ObservedObject var audio: AudioInputManager
    @ObservedObject var settings: SDRSettingsStore
    @AppStorage("digidec.tuningDisplayStyle") private var style = "tuning"

    var body: some View {
        Group {
            if style == "smeter" {
                AnalogSMeterPanel(controller: controller, audio: audio, settings: settings)
            } else {
                content
            }
        }
        .radioCard(title: "Abstimmanzeige", accessory: AnyView(toggle))
    }

    private var toggle: some View {
        ButtonGrid {
            Button("ABSTIMMUNG") { style = "tuning" }
                .buttonStyle(ModeButtonStyle(isSelected: style != "smeter", compact: true))
                .help("Abstimmanzeige des Moduls (Scope, Signalgüte, Mitte)")
            Button("S-METER") { style = "smeter" }
                .buttonStyle(ModeButtonStyle(isSelected: style == "smeter", compact: true))
                .help("Analoges S-Meter des SDR-Empfängers (IARU: S9 = −46 dBFS, 6 dB je S-Stufe)")
        }
    }
}

extension View {
    /// Karte „Abstimmanzeige“ mit Umschalter auf das analoge S-Meter
    func tuningCard(_ state: DigidecState) -> some View {
        TuningDisplayCard(content: self, controller: state.sdrController, audio: state.audio, settings: state.sdr)
    }
}

// MARK: - Karte mit Messwerten

struct AnalogSMeterPanel: View {
    @ObservedObject var controller: SDRController
    @ObservedObject var audio: AudioInputManager
    @ObservedObject var settings: SDRSettingsStore

    var body: some View {
        // Entwicklungshilfe für Schnappschüsse: DIGIDEC_SMETER_DEMO=<dBFS> zeigt das beleuchtete Instrument ohne Empfänger
        let demo = ProcessInfo.processInfo.environment["DIGIDEC_SMETER_DEMO"].flatMap(Double.init)
        let running: Bool = { if case .running = controller.status { return true } else { return false } }()
        let live = demo != nil || (audio.sourceKind == .sdr && controller.isSelected && !controller.isSuspended && running)
        let db = demo ?? (live ? controller.snapshot.metrics.signalDB : SDRSMeterScale.minDB)
        VStack(spacing: 8) {
            AnalogSMeterView(db: db, lit: live)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if live {
                    let (sText, _) = SDRSMeterScale.reading(db: db)
                    Text(sText)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(SMeterView.zoneColor(for: db))
                    Text(String(format: "%+.0f dBFS", db))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.textMuted)
                    Spacer(minLength: 4)
                    Text(settings.mode.title)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdCyan)
                    Text(SDRFormat.frequency(settings.frequencyHz) + " MHz")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdAmber)
                } else {
                    Text("KEIN SDR-EMPFANG")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                        .tracking(1.0)
                    Spacer(minLength: 0)
                }
            }
            .lineLimit(1)
        }
    }
}

// MARK: - Instrument

/// Analoges S-Meter im Stil der Transceiver der 1970er/80er Jahre: Metallrahmen mit Schrauben, hinterleuchtete Skala (Bernstein),
/// S-Stufen nach IARU, rote Zone über S9, zweite Skala in dBFS, Zeiger mit Schatten, Glasreflex.
struct AnalogSMeterView: View {
    let db: Double
    let lit: Bool
    @State private var ballistics = NeedleBallistics()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { ctx, size in
                let target = SDRSMeterScale.fraction(db: db)
                let needle = ballistics.step(target: target, now: timeline.date)
                SMeterPainter(size: size, needle: needle, lit: lit).draw(&ctx)
            }
        }
        .aspectRatio(1.75, contentMode: .fit)
        .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
        .accessibilityLabel("S-Meter")
    }
}
