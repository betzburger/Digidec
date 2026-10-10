// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

/// Einstellungs- und Steuerungs-Dialog für den Web-Fernzugriff im RadioTheme.
public struct WebServerSheet: View {
    @ObservedObject var server: DigidecWebServer
    let onClose: () -> Void

    @State private var portString = ""
    @State private var copiedLocal = false
    @State private var copiedLAN = false
    @State private var copiedBonjour = false

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

                // Zugriffsadressen für den Browser
                VStack(alignment: .leading, spacing: 8) {
                    Text("ZUGRIFFSADRESSEN:")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdAmber)

                    // 1. Auf diesem Mac (localhost)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Lokal auf diesem Mac:")
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundColor(RadioTheme.textDim)

                        HStack(spacing: 8) {
                            Text(server.localURL)
                                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                .foregroundColor(server.isRunning ? RadioTheme.vfdCyan : RadioTheme.textMuted)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(RadioTheme.bgDeep)
                                .cornerRadius(4)
                                .textSelection(.enabled)

                            if server.isRunning, let url = URL(string: server.localURL) {
                                Button("IM BROWSER ÖFFNEN") {
                                    NSWorkspace.shared.open(url)
                                }
                                .buttonStyle(ModeButtonStyle(isSelected: true))
                            }

                            Button(copiedLocal ? "KOPIERT!" : "KOPIEREN") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(server.localURL, forType: .string)
                                copiedLocal = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    copiedLocal = false
                                }
                            }
                            .buttonStyle(ModeButtonStyle(isSelected: false))
                            .disabled(!server.isRunning)
                        }
                    }

                    // 2. Im lokalen Netzwerk (iPad, Smartphone, Zweitrechner)
                    if let lanURL = server.lanURL {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Im lokalen Netzwerk (iPad, Smartphone, Zweit-Mac):")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundColor(RadioTheme.textDim)

                            HStack(spacing: 8) {
                                Text(lanURL)
                                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                    .foregroundColor(server.isRunning ? RadioTheme.vfdCyan : RadioTheme.textMuted)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(RadioTheme.bgDeep)
                                    .cornerRadius(4)
                                    .textSelection(.enabled)

                                Button(copiedLAN ? "KOPIERT!" : "KOPIEREN") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(lanURL, forType: .string)
                                    copiedLAN = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                        copiedLAN = false
                                    }
                                }
                                .buttonStyle(ModeButtonStyle(isSelected: false))
                                .disabled(!server.isRunning)
                            }
                        }
                    }

                    // 3. Bonjour mDNS (falls vorhanden)
                    if let bonjourURL = server.bonjourURL {
                        HStack(spacing: 6) {
                            Text("Bonjour (mDNS):")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(RadioTheme.textMuted)
                            Text(bonjourURL)
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(server.isRunning ? RadioTheme.vfdGreen.opacity(0.8) : RadioTheme.textMuted)
                                .textSelection(.enabled)
                            Button(copiedBonjour ? "KOPIERT!" : "KOPIEREN") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(bonjourURL, forType: .string)
                                copiedBonjour = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    copiedBonjour = false
                                }
                            }
                            .buttonStyle(ModeButtonStyle(isSelected: false))
                            .font(.system(size: 8.5, design: .monospaced))
                            .disabled(!server.isRunning)
                        }
                        .padding(.top, 1)
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
                bulletPoint("Live-Audio: Ton des Empfängers im Browser, bei UKW-Rundfunk in Stereo mit 48 kHz.")
                bulletPoint("Wasserfall: NF mit Hz-Skala und Zoom, HF des SDR mit Frequenzskala, Zoom bis 32× und Abstimmen per Klick.")
                bulletPoint("Bedienung: Module, Frequenz (auch eintippen), Betriebsart USB/LSB/CW/AM/FM/WFM und SDR-Gerät.")
                bulletPoint("Text und Listen aller Module (auch nach dem Umschalten vollständig), Karte mit Flugzeug- und Schiffsymbolen.")
                bulletPoint("Nur in der App: MEHRKANAL, Bilder (SSTV, Wetterfax), Einstellungen der Module.")
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

    private func bulletPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("·").foregroundColor(RadioTheme.vfdCyan).font(.system(size: 11, weight: .black))
            Text(LocalizedStringKey(text))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
        }
    }
}
