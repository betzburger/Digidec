import SwiftUI

/// Dialog „Funkgerät“: Digidec bekommt Frequenz und Mode von einem rigctld. Entweder automatisch vom Commander, dessen USB-Codec
/// gelesen wird, oder von einem frei eingestellten Gerät (Rechner, Port, Name, Audio-Eingang), also von allem, was Hamlib kann.
struct RigSettingsSheet: View {
    @ObservedObject var state: DigidecState
    @ObservedObject var store: RigProfileStore
    @ObservedObject var rig: RigModel
    @ObservedObject var audio: AudioInputManager
    @Environment(\.dismiss) private var dismiss

    /// Das Gerät, das gerade bearbeitet wird
    @State private var editingID: String?
    @State private var draft = RigProfile(name: "")
    @State private var testMessage: String?
    @State private var testSucceeded = false
    @State private var testing = false

    init(state: DigidecState) {
        self.state = state
        self.store = state.rigProfiles
        self.rig = state.rig
        self.audio = state.audio
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("FUNKGERÄT")
                    .font(.system(size: 14, weight: .black, design: .monospaced))
                    .foregroundColor(RadioTheme.textBright)
                Spacer()
                Button("SCHLIESSEN") { dismiss() }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .keyboardShortcut(.cancelAction)
            }
            Text("Digidec liest Frequenz und Mode von einem rigctld (Hamlib) und stellt das Funkgerät nur auf Wunsch ein (Schalter QSY AUTO, "
                 + "nur Frequenz und Mode, nie Senden). Jedes Funkgerät, das ein rigctld bedient, lässt sich einbinden.")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            if rig.overriddenByRequest {
                Text("Ein Auftrag per URL hat die Wahl für diese Sitzung übersteuert: \(rig.rigName ?? "Automatik"). Eine Wahl hier gilt wieder dauerhaft.")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdAmber)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    automaticRow
                    ForEach(store.list.profiles) { profile in
                        profileRow(profile)
                    }
                    Button {
                        let added = store.add(RigProfile(name: ""))
                        edit(added)
                    } label: {
                        Label("NEUES FUNKGERÄT", systemImage: "plus")
                    }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .padding(.top, 2)

                    if editingID != nil {
                        editor
                    }
                    hints
                }
                .padding(.trailing, 4)
            }
        }
        .padding(18)
        .frame(width: 600, height: 640)
        .background(RadioTheme.bgPanel)
        .onAppear { audio.refreshDevices() }
    }

    // MARK: Zeilen

    private var automaticRow: some View {
        Button {
            state.activateRigProfile(id: nil)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: store.list.active == nil ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(store.list.active == nil ? RadioTheme.vfdCyan : RadioTheme.textMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatik: Commander (IC-PCR1500, FT-991A)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.textBright)
                    Text("Audio direkt vom USB-Codec des Geräts, rigctld der Commander auf diesem Rechner (Port 4532 bzw. 4533)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(RadioTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(RadioTheme.bgDeep)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    private func profileRow(_ profile: RigProfile) -> some View {
        let isActive = store.list.activeID == profile.id
        return HStack(alignment: .top, spacing: 10) {
            Button {
                state.activateRigProfile(id: profile.id)
            } label: {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(isActive ? RadioTheme.vfdCyan : RadioTheme.textMuted)
            }
            .buttonStyle(.plain)
            .help("Dieses Funkgerät verwenden")
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textBright)
                Text("rigctld \(profile.host):\(profile.port)" + (profile.audioName.map { " · Audio: \($0)" } ?? "")
                     + (profile.problem.map { " · \($0)" } ?? ""))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(profile.problem == nil ? RadioTheme.textMuted : RadioTheme.ledRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button {
                edit(profile)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(ModeButtonStyle(isSelected: editingID == profile.id))
            .help("Bearbeiten")
        }
        .padding(8)
        .background(RadioTheme.bgDeep)
        .cornerRadius(6)
    }

    // MARK: Bearbeiten

    private func edit(_ profile: RigProfile) {
        editingID = profile.id
        draft = profile
        testMessage = nil
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BEARBEITEN")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            labeled("Name") {
                TextField("z. B. IC-7300", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }
            labeled("Rechner") {
                TextField("127.0.0.1 oder Name", text: $draft.host)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }
            labeled("Port") {
                TextField("4532", value: $draft.port, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }
            labeled("Audio-Eingang") {
                Picker("", selection: $draft.audioUID) {
                    Text("keinen bestimmten (Wahl im Eingangsmenü)").tag(String?.none)
                    ForEach(audio.devices) { device in
                        Text(device.name).tag(String?.some(device.id))
                    }
                }
                .labelsHidden()
                .onChange(of: draft.audioUID) { _, uid in
                    draft.audioName = audio.devices.first { $0.id == uid }?.name
                }
            }
            if let problem = draft.problem {
                Text(problem)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(RadioTheme.ledRed)
            } else if let endpoint = draft.endpoint, !endpoint.isLoopback {
                Text("Rechner im Netz: Die Verbindung zum rigctld ist unverschlüsselt und ohne Anmeldung. Nur in einem vertrauenswürdigen Netz verwenden.")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(RadioTheme.vfdAmber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Button {
                    test()
                } label: {
                    Label(testing ? "TESTE …" : "TESTEN", systemImage: "bolt.horizontal")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .disabled(draft.endpoint == nil || testing)
                .help("Verbindung herstellen und Frequenz und Mode abfragen")
                Button("SPEICHERN") { save() }
                    .buttonStyle(ModeButtonStyle(isSelected: false))
                    .disabled(draft.problem != nil)
                Button("SPEICHERN UND VERWENDEN") {
                    save()
                    state.activateRigProfile(id: draft.id)
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
                .disabled(draft.problem != nil)
                Spacer()
                Button {
                    delete()
                } label: {
                    Label("LÖSCHEN", systemImage: "trash")
                }
                .buttonStyle(ModeButtonStyle(isSelected: false))
            }
            if let testMessage {
                Text(testMessage)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(testSucceeded ? RadioTheme.vfdGreen : RadioTheme.ledYellow)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RadioTheme.bgCard)
        .cornerRadius(6)
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
                .frame(width: 100, alignment: .leading)
            content()
        }
    }

    private func save() {
        store.update(draft)
    }

    private func delete() {
        store.remove(id: draft.id)
        editingID = nil
        testMessage = nil
    }

    private func test() {
        guard let endpoint = draft.endpoint else { return }
        testing = true
        testMessage = nil
        RigctlClient.probe(endpoint) { result in
            Task { @MainActor in
                testing = false
                testMessage = result.message
                if case .ok = result { testSucceeded = true } else { testSucceeded = false }
            }
        }
    }

    // MARK: Hinweise

    private var hints: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SO STARTEST DU RIGCTLD")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
            Text("Hamlib installieren (z. B. brew install hamlib) und im Terminal starten: rigctld -m <Modellnummer> -r <Anschluss> -s <Baudrate>. "
                 + "Die Modellnummern zeigt rigctl -l. rigctld hört standardmäßig auf Port 4532. "
                 + "Mehrere Geräte brauchen verschiedene Ports (Option -t). Die Commander bringen ihren rigctld selbst mit.")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Text("Digidec sendet an das Gerät nur f und m (lesen), mit QSY AUTO zusätzlich F und M (Frequenz und Mode setzen). "
                 + "Nie PTT, Leistung oder Lautstärke. Den Audio-Eingang des Geräts (USB-Soundkarte, Codec) wählst du hier oder im Eingangsmenü.")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }
}
