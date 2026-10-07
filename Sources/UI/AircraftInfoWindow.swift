// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

// MARK: - Fenster „Flugzeugdaten“

/// Foto, Typ, Betreiber und planmäßige Strecke zu einem Flugzeug der ADS-B-Liste (Daten aus dem Netz, siehe `AircraftInfoService`)
struct AircraftInfoWindow: View {
    @ObservedObject var controller: ADSBController
    @ObservedObject var settings: ADSBSettingsStore
    @ObservedObject var home: HomeLocation

    var body: some View {
        ZStack {
            RadioTheme.bgPanel.ignoresSafeArea()
            if let icao = controller.infoICAO {
                content(icao)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "airplane").font(.system(size: 34)).foregroundColor(RadioTheme.textDim)
                    Text("Ein Flugzeug in der Liste doppelt anklicken oder in der Karte wählen und FLUGZEUGDATEN drücken.")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(RadioTheme.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(20)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 560)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func content(_ icao: UInt32) -> some View {
        let live = controller.aircraft(icao)
        let web = controller.details[icao]
        let loading = controller.detailsLoading.contains(icao)
        let q = AircraftQuery(icao: icao, callsign: live?.callsign)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header(icao, live, web)
                photo(web, loading: loading)
                if let route = web?.route { routeCard(route, live) }
                if settings.webLookup { aircraftFacts(web, loading: loading) } else { offlineHint(icao, live) }
                liveFacts(icao, live)
                radioTraffic(live)
                links(q, web)
                footer(icao, live)
            }
            .padding(14)
        }
        .task(id: "\(icao)-\(live?.callsign ?? "")-\(settings.webLookup)") {
            if settings.webLookup { await controller.loadDetails(icao, callsign: live?.callsign, photo: true) }
        }
    }

    // MARK: Funkverkehr (ACARS) desselben Flugzeugs

    @ViewBuilder
    private func radioTraffic(_ live: ADSBAircraft?) -> some View {
        if let live {
            let messages = DigidecState.shared.acarsMessages(for: live).suffix(8)
            if !messages.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle("FUNKVERKEHR (ACARS) · \(messages.count) NEUESTE")
                    ForEach(Array(messages)) { m in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(ACARSController.utc.string(from: m.time)).frame(width: 66, alignment: .leading)
                            Image(systemName: m.isDownlink ? "arrow.down" : "arrow.up").font(.system(size: 8, weight: .bold)).frame(width: 12)
                            Text(m.label).frame(width: 24, alignment: .leading)
                            Text(m.isEmpty ? (ACARSLabels.describe(m.label) ?? "ohne Text") : m.text.replacingOccurrences(of: "\n", with: " ⏎ "))
                                .frame(maxWidth: .infinity, alignment: .leading).lineLimit(3)
                        }
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(m.isDownlink ? RadioTheme.vfdGreen : RadioTheme.vfdCyan)
                    }
                }
            }
        }
    }

    // MARK: Kopf und Foto

    private func header(_ icao: UInt32, _ live: ADSBAircraft?, _ web: AircraftWebInfo?) -> some View {
        let country = ICAORanges.shared.country(icao)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(country?.flag ?? "✈︎").font(.system(size: 26))
                Text(live?.callsign ?? web?.registration ?? String(format: "%06X", icao))
                    .font(.system(size: 22, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdCyan)
            }
            Text([web?.fullTypeName, web?.owner ?? web?.route?.airlineName, country?.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
            HStack(spacing: 6) {
                chip("ICAO " + String(format: "%06X", icao))
                if let r = web?.registration { chip(r) }
                if let t = web?.icaoType { chip(t) }
                if let f = web?.route?.flightNumber, !f.isEmpty { chip(f) }
            }
        }
    }

    private func chip(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(RadioTheme.vfdAmber)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RadioTheme.bgDeep)
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(RadioTheme.borderSubtle, lineWidth: 1))
            .textSelection(.enabled)
    }

    @ViewBuilder
    private func photo(_ web: AircraftWebInfo?, loading: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(RadioTheme.bgDeep)
                if let s = web?.photo?.imageURL, let url = URL(string: s) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image): image.resizable().scaledToFill()
                        case .failure: placeholder("Foto konnte nicht geladen werden")
                        default: ProgressView().controlSize(.small)
                        }
                    }
                } else if loading {
                    ProgressView("Suche im Netz …").controlSize(.small).font(.system(size: 10, design: .monospaced))
                } else {
                    placeholder(settings.webLookup ? "Kein Foto gefunden" : "Netz-Suche ist aus")
                }
            }
            .frame(height: 250)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(RadioTheme.borderSubtle, lineWidth: 1))
            if let p = web?.photo {
                HStack(spacing: 4) {
                    Text("Foto" + (p.photographer.map { ": \($0)" } ?? "") + " · \(p.source)" + (p.source == "airport-data.com" ? " (Foto kann ein anderes Flugzeug zeigen)" : ""))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                        .lineLimit(2)
                    if let page = p.pageURL, let u = URL(string: page) {
                        Link("Fotoseite", destination: u).font(.system(size: 9, weight: .bold, design: .monospaced))
                    }
                }
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "airplane").font(.system(size: 40)).foregroundColor(RadioTheme.textDim)
            Text(text).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(RadioTheme.textMuted)
        }
    }

    // MARK: Strecke

    private func routeCard(_ r: AircraftRoute, _ live: ADSBAircraft?) -> some View {
        let progress = AircraftProgress.compute(route: r, position: live?.position, groundSpeedKn: live?.groundSpeedKn)
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("STRECKE LAUT FLUGPLAN" + (r.airlineName.isEmpty ? "" : " · " + r.airlineName))
            HStack(alignment: .top, spacing: 10) {
                place(r.origin, label: "START")
                Image(systemName: "airplane").font(.system(size: 18)).foregroundColor(RadioTheme.vfdCyan).padding(.top, 14)
                place(r.destination, label: "ZIEL")
            }
            if let p = progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(RadioTheme.bgDeep)
                        RoundedRectangle(cornerRadius: 3).fill(RadioTheme.vfdCyan.opacity(0.7)).frame(width: geo.size.width * p.fraction)
                    }
                }
                .frame(height: 6)
                Text(String(format: "%.0f %% geflogen · %.0f km zurückgelegt · noch %.0f km", p.fraction * 100, p.flownKm, p.remainingKm) + (p.etaText.map { " · ca. \($0)" } ?? ""))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.textMuted)
                Text("Luftlinie, nach der gehörten Geschwindigkeit. Die Strecke gilt für das Rufzeichen; bei Umleitungen, Charter- und Privatflügen kann sie abweichen.")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let d = r.distanceKm {
                Text(String(format: "Luftlinie %.0f km", d)).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(RadioTheme.textMuted)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RadioTheme.bgDeep.opacity(0.6))
        .cornerRadius(6)
    }

    private func place(_ p: AircraftPlace?, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(RadioTheme.textDim)
            Text(p?.shortCode ?? "?").font(.system(size: 22, weight: .black, design: .monospaced)).foregroundColor(RadioTheme.vfdGreen)
            Text(p.map { $0.city.isEmpty ? $0.name : $0.city } ?? "unbekannt").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(RadioTheme.textBright)
            if let p {
                Text("\(p.name)\(p.icao.isEmpty ? "" : " · \(p.icao)") · \(p.countryName)").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundColor(RadioTheme.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Daten

    @ViewBuilder
    private func aircraftFacts(_ web: AircraftWebInfo?, loading: Bool) -> some View {
        if let w = web, w.hasAircraft {
            VStack(alignment: .leading, spacing: 4) {
                sectionTitle("FLUGZEUG · AUS DEM NETZ")
                table(Self.factRows(w))
            }
        } else if loading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Frage adsbdb und planespotters …").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(RadioTheme.textMuted)
            }
        } else if let w = web {
            VStack(alignment: .leading, spacing: 3) {
                sectionTitle("FLUGZEUG · AUS DEM NETZ")
                ForEach(w.notes, id: \.self) { n in
                    Text(n).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(RadioTheme.textMuted).fixedSize(horizontal: false, vertical: true)
                }
                if w.notes.isEmpty {
                    Text("Zu dieser Adresse ist nichts bekannt.").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(RadioTheme.textMuted)
                }
            }
        }
    }

    static func factRows(_ w: AircraftWebInfo) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let r = w.registration { rows.append(("Registrierung", r)) }
        if let t = w.fullTypeName { rows.append(("Typ", t + (w.icaoType.map { " (\($0))" } ?? ""))) }
        if let o = w.owner { rows.append(("Eigner / Betreiber", o)) }
        if let c = w.ownerCountryName { rows.append(("Registriert in", c)) }
        if let r = w.route, !r.airlineName.isEmpty { rows.append(("Fluggesellschaft", r.airlineName + (r.airlineICAO.isEmpty ? "" : " (\(r.airlineICAO))"))) }
        if let r = w.route, !r.flightNumber.isEmpty { rows.append(("Flugnummer", r.flightNumber)) }
        return rows
    }

    private func offlineHint(_ icao: UInt32, _ live: ADSBAircraft?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("AUS DEM NETZ")
            Text("Die Netz-Suche ist aus. Sie schickt nur die ICAO-Adresse und das Rufzeichen dieses Flugzeugs an adsbdb.com und planespotters.net.")
                .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(RadioTheme.textMuted).fixedSize(horizontal: false, vertical: true)
            Button("IM NETZ SUCHEN") {
                settings.webLookup = true
            }
            .buttonStyle(ModeButtonStyle(isSelected: false))
        }
    }

    private func liveFacts(_ icao: UInt32, _ a: ADSBAircraft?) -> some View {
        var rows: [(String, String)] = []
        if let a {
            if let alt = a.altitudeFt { rows.append(("Höhe", a.onGround == true ? "Am Boden" : "\(alt) ft · \(a.altitudeText ?? "") · \(Int((Double(alt) * 0.3048).rounded())) m" + (a.altitudeIsGNSS ? " (GNSS)" : ""))) }
            if let v = a.groundSpeedKn { rows.append(("Geschwindigkeit", String(format: "%.0f kn · %.0f km/h", v, v * 1.852) + (a.trackDeg.map { String(format: " · Kurs %.0f°", $0) } ?? ""))) }
            if let vr = a.verticalRateFpm, vr != 0 { rows.append((vr > 0 ? "Steigen" : "Sinken", "\(abs(vr)) ft/min")) }
            if let sq = a.squawk { rows.append(("Kennung (Squawk)", sq + (a.emergencyText.map { " · ⚠ \($0)" } ?? ""))) }
            if let c = a.categoryText { rows.append(("Kategorie", c)) }
            if let p = a.position { rows.append(("Position", Geo.format(p))) }
            if let p = a.position, let h = home.point {
                let km = Geo.distanceKm(h, p), b = Geo.bearing(from: h, to: p)
                rows.append(("Entfernung", "\(Geo.formatKm(km)) · \(Geo.compass(b)) \(Int(b.rounded()))°"))
            }
            if let r = a.maxRangeKm { rows.append(("Weitester Empfang", String(format: "%.0f km", r))) }
            rows.append(("Empfang", "\(a.messages) Meldungen · \(a.positionMessages) Positionen" + (a.levelDB.map { String(format: " · %.0f dB", $0) } ?? "")))
        } else {
            rows.append(("Empfang", "Das Flugzeug ist nicht mehr in der Liste."))
        }
        return VStack(alignment: .leading, spacing: 4) {
            sectionTitle("AUS DEM ADS-B-SIGNAL (LIVE)")
            table(rows)
        }
    }

    private func table(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(r.0)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                        .frame(width: 130, alignment: .leading)
                    Text(r.1)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textBright)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RadioTheme.bgDeep.opacity(0.6))
        .cornerRadius(6)
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(RadioTheme.textDim)
            .tracking(1.2)
    }

    // MARK: Verweise und Fuß

    private func links(_ q: AircraftQuery, _ web: AircraftWebInfo?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("MEHR IM NETZ (IM BROWSER)")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(AircraftLinks.links(for: q, info: web)) { l in
                    Button {
                        NSWorkspace.shared.open(l.url)
                    } label: {
                        Label(l.title, systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .help(l.detail + " – öffnet " + (l.url.host ?? ""))
                }
            }
        }
    }

    private func footer(_ icao: UInt32, _ live: ADSBAircraft?) -> some View {
        HStack(spacing: 8) {
            Button {
                Task { await controller.loadDetails(icao, callsign: live?.callsign, photo: true, force: true) }
            } label: {
                Label("NEU ABFRAGEN", systemImage: "arrow.clockwise")
            }
            .buttonStyle(ModeButtonStyle(isSelected: false))
            .disabled(controller.detailsLoading.contains(icao) || !settings.webLookup)
            .help("Zwischenspeicher übergehen und adsbdb und planespotters neu fragen")
            Text("Daten: adsbdb.com (Gemeinschaftsdatenbank), Fotos: planespotters.net mit Fotograf. Abfrage nur mit ICAO-Adresse und Rufzeichen.")
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
