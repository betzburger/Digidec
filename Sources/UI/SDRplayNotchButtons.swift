// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI

/// Schalter für die Notch-Filter der SDRplay-Geräte (RF-Notch gegen Rundfunk, DAB-Notch gegen Band III). Beide gehören zum Gerät und
/// werden beim nächsten Start der Quelle gesetzt; was das Gerät nicht hat, nimmt die API nicht an und es bleibt wirkungslos.
struct SDRplayNotchButtons: View {
    @Binding var rf: Bool
    @Binding var dab: Bool
    /// Hinweis, den das Modul zu den Notches gibt
    var hint: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text(LocalizedStringKey("NOTCH"))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            Button("RF") { rf.toggle() }
                .buttonStyle(ModeButtonStyle(isSelected: rf))
                .help("RF-Notch des SDRplay: schaltet das Notch-Filter gegen Rundfunk ein (am RSPduo gemessen: UKW-Rundfunk um etwa 20 dB gedämpft). Hilft, wenn starke Rundfunksender in der Nähe den Eingang übersteuern. Gibt es beim RSP1A/1B, RSP2, RSPduo (Tuner A) und RSPdx; der RSP1 hat keinen.")
            Button("DAB") { dab.toggle() }
                .buttonStyle(ModeButtonStyle(isSelected: dab))
                .help("DAB-Notch des SDRplay: schaltet das Notch-Filter für Band III (174 … 240 MHz) ein. Am RSPduo gemessen dämpft es 222 MHz um etwa 14 dB, auch Frequenzen darunter. Das ist keine Sperre: bei einem starken DAB-Sender in der Nähe, der den Eingang übersteuert, kann es den Empfang erst möglich machen. Gibt es beim RSP1A/1B, RSPduo (Tuner A) und RSPdx." + (hint.map { "\n" + $0 } ?? ""))
        }
    }
}

/// Hilfetexte der Verstärkungsregler des SDRplay (gemeinsam für alle Module)
enum SDRplayHelp {
    static let lna = "Dämpfung des rauscharmen Vorverstärkers (LNA) direkt hinter der Antenne. Stufe 0 = keine Dämpfung = höchste Verstärkung; jede höhere Stufe dämpft stärker, das Gerät verstärkt also weniger. Bei Übersteuerung durch starke Sender in der Nähe auf „+“ klicken (höhere Stufe), bei schwachen Signalen auf „−“. Der nutzbare Bereich hängt von Gerät und Frequenz ab."
    static let ifGain = "Dämpfung im Zwischenfrequenzteil (hinter dem Mischer), 20 bis 59 dB; mehr dB = weniger Verstärkung. Wirkt nur bei ausgeschalteter AGC und hilft nicht gegen Übersteuerung am Eingang: dafür die LNA-Dämpfung erhöhen."
}

/// Warnung bei Übersteuerung des SDRplay (die API meldet sie, wenn der Eingang des Geräts übersteuert). Erscheint nur, wenn es eine gibt.
struct SDRplayOverloadHint: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            switch SDRplayAPISource.overload {
            case .none:
                EmptyView()
            case .recent:
                Text(LocalizedStringKey("SDRplay war kurz übersteuert. Wenn der Empfang gestört ist: bei LNA-DÄMPFUNG auf „+“ klicken (weniger Verstärkung)."))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdAmber)
                    .fixedSize(horizontal: false, vertical: true)
            case .active:
                Text(LocalizedStringKey("SDRplay übersteuert: zu viel Signal am Eingang. Weniger Verstärkung einstellen: bei LNA-DÄMPFUNG auf „+“ klicken (höhere Stufe = weniger Verstärkung), alternativ die Notch einschalten."))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.ledRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help("Die API des SDRplay meldet, wenn der Eingang des Geräts übersteuert ist (Wandler am Anschlag). Dann sind Empfang und Decodierung gestört, auch wenn das Signal sehr stark und eigentlich gut ist.")
    }
}
