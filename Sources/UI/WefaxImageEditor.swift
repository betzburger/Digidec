import SwiftUI
import AppKit

/// Bild nachbearbeiten: zyklisch nach links/rechts verschieben, wenn der Empfang den Zeilenanfang falsch getroffen hat
struct WefaxImageEditor: View {
    let controller: WefaxController
    let image: WefaxImage
    @State private var shift = 0
    @State private var message: String?
    @State private var autoNote: String?
    @Environment(\.dismiss) private var dismiss

    private var half: Int { image.width / 2 }

    private var preview: CGImage? {
        let px = WefaxImageTools.shifted(image.pixels, width: image.width, height: image.height, by: shift)
        return WefaxController.cgImage(pixels: px, width: image.width, height: image.height)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("BILD VERSCHIEBEN")
                    .font(.system(size: 14, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.textBright)
                Text(image.name)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .lineLimit(1)
                Spacer()
                Button("SCHLIESSEN") { dismiss() }.buttonStyle(ModeButtonStyle(isSelected: false))
            }

            Group {
                if let cg = preview {
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(CGFloat(image.width) / CGFloat(max(image.height, 1)), contentMode: .fit)
                } else {
                    Color.white
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
            .cornerRadius(4)

            HStack(spacing: 8) {
                Text("Verschiebung")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                Slider(value: Binding(get: { Double(shift) }, set: { shift = Int($0.rounded()) }),
                       in: Double(-half)...Double(half))
                Text(String(format: "%+d px", shift))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdCyan)
                    .frame(width: 70, alignment: .trailing)
            }

            HStack(spacing: 6) {
                ForEach([-100, -10, -1], id: \.self) { d in
                    Button(String(format: "%+d", d)) { nudge(d) }.buttonStyle(ModeButtonStyle(isSelected: false))
                }
                ForEach([1, 10, 100], id: \.self) { d in
                    Button(String(format: "%+d", d)) { nudge(d) }.buttonStyle(ModeButtonStyle(isSelected: false))
                }
                Button {
                    let dx = WefaxImageTools.autoShift(image.pixels, width: image.width, height: image.height)
                    shift = dx
                    autoNote = dx == 0 ? "Kein heller Randstreifen gefunden – von Hand verschieben" : "Heller Randstreifen an den Bildrand gelegt"
                } label: {
                    Label("AUTO", systemImage: "wand.and.stars")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .help("Sucht den weißen Randstreifen der Wetterkarte und legt ihn an den Bildrand")
                Button("ZURÜCK") { shift = 0; autoNote = nil }.buttonStyle(ModeButtonStyle(isSelected: false))
                Spacer()
                Button("NEU SPEICHERN") { save(replace: false) }
                    .buttonStyle(ModeButtonStyle(isSelected: shift != 0))
                    .disabled(shift == 0)
                    .help("Als neue Datei „…_korr.png“ neben dem Original ablegen")
                Button("ORIGINAL ERSETZEN") { save(replace: true) }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .disabled(shift == 0)
                    .help("Datei ersetzen; das Original bleibt einmalig als „…_original.png“ erhalten")
            }

            if let note = autoNote ?? message {
                Text(message ?? note)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(message?.hasPrefix("Gespeichert") == true ? RadioTheme.vfdGreen : RadioTheme.textDim)
            }
        }
        .padding(16)
        .frame(width: 940, height: 700)
        .background(RadioTheme.bgPanel)
        .onAppear {
            // Gleich einen Vorschlag zeigen: bei klarer Naht wird sie automatisch gesetzt
            let dx = WefaxImageTools.autoShift(image.pixels, width: image.width, height: image.height)
            if dx != 0 { shift = dx; autoNote = "Vorschlag: heller Randstreifen an den Bildrand gelegt – bei Bedarf nachstellen" }
        }
    }

    private func nudge(_ d: Int) {
        var v = shift + d
        if v > half { v -= image.width }
        if v < -half { v += image.width }
        shift = v
    }

    private func save(replace: Bool) {
        do {
            let saved = try controller.saveEdited(image, shift: shift, replaceOriginal: replace)
            message = "Gespeichert: \(saved.name)"
        } catch {
            message = "Speichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }
}
