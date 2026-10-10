// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

/// Einstellungs- und Steuerungs-Dialog für den Web-Fernzugriff im RadioTheme.
public struct WebServerSheet: View {
    @ObservedObject var server: DigidecWebServer
    let onClose: () -> Void

    @State private var portString = ""
    @State private var copied = false

    public init(server: DigidecWebServer, onClose: @escaping () -> Void) {
        self.server = server
        self.onClose = onClose
        _portString = State(initialValue: "\(server.port)")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(server.isRunning ? RadioTheme.vfdGreen : RadioTheme.ledRed)
                        .frame(width: 9, height: 9)
                        .shadow(color: (server.isRunning ? RadioTheme.vfdGreen : RadioTheme.ledRed).opacity(0.8), radius: 4)
                    Text("WEB-FERNZUGRIFF & HTTP-SERVER")
                        .font(.system(size: 13, weight: .black, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdCyan)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
            }

            Divider().background(RadioTheme.borderSubtle)

            // Info & Status
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Button(server.isRunning ? "SERVER STOPPEN" : "SERVER STARTEN") {
                        server.toggle()
                    }
                    .buttonStyle(ModeButtonStyle(isSelected: server.isRunning))

                    if server.isRunning {
                        Text("AKTIV · \(server.clientCount) VERBUNDENE CLIENTS")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(RadioTheme.vfdGreen)
                    } else {
                        Text("ANGEHALTEN")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(RadioTheme.textDim)
                    }
                }

                if let err = server.lastError {
                    Text(err)
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.ledRed)
                }

                // Port Einstellung
                HStack(spacing: 8) {
                    Text("Netzwerk-Port:")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                    TextField("8080", text: $portString)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 80)
                        .disabled(server.isRunning)
                        .onSubmit {
                            if let p = UInt16(portString), p > 1024 {
                                server.port = p
                            } else {
                                portString = "\(server.port)"
                            }
                        }
                    if server.isRunning {
                        Text("(Änderung nur bei gestopptem Server)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(RadioTheme.textMuted)
                    }
                }

                // Web-URL zum Aufrufen
                VStack(alignment: .leading, spacing: 4) {
                    Text("Zugriffsadresse für den Browser:")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)

                    HStack(spacing: 8) {
                        Text(webUrlString)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(server.isRunning ? RadioTheme.vfdCyan : RadioTheme.textMuted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(RadioTheme.bgDeep)
                            .cornerRadius(4)
                            .textSelection(.enabled)

                        Button(copied ? "KOPIERT!" : "ADRESSE KOPIEREN") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(webUrlString, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                copied = false
                            }
                        }
                        .buttonStyle(ModeButtonStyle(isSelected: false))
                        .disabled(!server.isRunning)

                        if server.isRunning, let url = URL(string: webUrlString) {
                            Button("IM BROWSER ÖFFNEN") {
                                NSWorkspace.shared.open(url)
                            }
                            .buttonStyle(ModeButtonStyle(isSelected: true))
                        }
                    }
                }
                .padding(.top, 4)
            }
            .padding(12)
            .background(RadioTheme.bgDeep.opacity(0.6))
            .cornerRadius(6)

            // Funktionsumfang Übersicht
            VStack(alignment: .leading, spacing: 5) {
                Text("FUNKTIONSUMFANG DES REMOTE-DASHBOARDS:")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdAmber)
                bulletPoint("Live-Audio: Echzeit-Audioausgabe über die Web Audio API des Zielgeräts (iPad, Smartphone, Laptop).")
                bulletPoint("HF- & Audio-Wasserfall: Flüssiges 30-FPS Canvas-Streaming im originalen RadioTheme Farbverlauf.")
                bulletPoint("Fernsteuerung: Umschalten der Decoder-Module und feinstufige Frequenzabstimmung.")
                bulletPoint("Echtzeit-Textausgabe: Sofortiges Streaming decodierter Meldungen (RTTY, NAVTEX, CW, PSK).")
            }
            .padding(.horizontal, 4)

            Divider().background(RadioTheme.borderSubtle)

            // Schließen Button
            HStack {
                Spacer()
                Button("SCHLIESSEN", action: onClose)
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 520)
        .background(RadioTheme.bgPanel)
        .preferredColorScheme(.dark)
    }

    private var webUrlString: String {
        let host = ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? "localhost"
        return "http://\(host).local:\(server.port)"
    }

    private func bulletPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("·").foregroundColor(RadioTheme.vfdCyan).font(.system(size: 11, weight: .black))
            Text(text)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
        }
    }
}
