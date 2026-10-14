// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Was dem Sprachmodell mitgegeben wird: Systemanweisung und Kontext zur Frage (Signal im Wasserfall, markierter Text, allgemein).
// Reine Logik (prüfbar). Der Kontext wird dem Nutzer vor dem Senden gezeigt.

/// Zustand des Empfängers zum Zeitpunkt der Frage
public struct AssistantTuning: Equatable, Sendable {
    public var moduleName: String
    public var frequencyHz: Double?
    public var mode: String?
    /// Quelle des Signals („SDR“, „AUDIO“, „DATEI“)
    public var source: String
    public var utc: Date
    /// Standort als Maidenhead-Locator, nur wenn der Nutzer es erlaubt
    public var locator: String?

    public init(moduleName: String, frequencyHz: Double? = nil, mode: String? = nil, source: String = "", utc: Date = Date(), locator: String? = nil) {
        self.moduleName = moduleName
        self.frequencyHz = frequencyHz
        self.mode = mode
        self.source = source
        self.utc = utc
        self.locator = locator
    }

    var lines: [String] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        var out = ["Modul in Digidec: \(moduleName)"]
        if !source.isEmpty { out.append("Eingang: \(source)") }
        if let fr = frequencyHz { out.append("Abstimmfrequenz: \(AssistantFormat.frequency(fr))" + (mode.map { " (\($0))" } ?? "")) }
        out.append("Zeit: \(f.string(from: utc))")
        if let l = locator { out.append("Standort des Empfängers (Locator): \(l)") }
        return out
    }
}

/// Eine vorbereitete Frage samt Kontext
public struct AssistantContext: Equatable, Sendable {
    public enum Kind: String, Sendable { case general, text, signal }

    public var kind: Kind
    public var title: String
    /// Kontext als Text, genau so geht er an das Modell
    public var text: String
    /// Wasserfall-Ausschnitt als PNG (nur bei Signalen)
    public var image: Data?
    public var suggestedQuestion: String

    public init(kind: Kind, title: String, text: String, image: Data? = nil, suggestedQuestion: String) {
        self.kind = kind
        self.title = title
        self.text = text
        self.image = image
        self.suggestedQuestion = suggestedQuestion
    }
}

public enum AssistantContextBuilder {
    /// Obergrenze für den Text, der mitgeschickt wird (Zeichen)
    public static let maxTextCharacters = 6000

    public static func general(tuning: AssistantTuning) -> AssistantContext {
        AssistantContext(kind: .general, title: "Allgemeine Frage",
                         text: "Zustand von Digidec:\n" + tuning.lines.joined(separator: "\n"),
                         suggestedQuestion: "")
    }

    /// Markierter Text samt Umgebung. `before` und `after` sind die Zeichen davor und danach (werden auf eine sinnvolle Länge gekürzt).
    public static func text(selection: String, before: String, after: String, tuning: AssistantTuning) -> AssistantContext {
        let sel = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        let budget = max(0, maxTextCharacters - sel.count)
        let b = String(before.suffix(min(budget / 2, 1500)))
        let a = String(after.prefix(min(budget / 2, 1500)))
        var parts = ["Zustand von Digidec:\n" + tuning.lines.joined(separator: "\n")]
        parts.append("Markierter Text (vom Decoder empfangen, Fehler durch schlechten Empfang möglich):\n<<<\n" + String(sel.prefix(maxTextCharacters)) + "\n>>>")
        if !b.isEmpty { parts.append("Text davor:\n" + b) }
        if !a.isEmpty { parts.append("Text danach:\n" + a) }
        let short = sel.replacingOccurrences(of: "\n", with: " ")
        return AssistantContext(kind: .text, title: "Markierter Text: " + (short.count > 40 ? String(short.prefix(40)) + "…" : short),
                                text: parts.joined(separator: "\n\n"), suggestedQuestion: "Was bedeutet dieser Text? Um welches Verfahren oder welchen Dienst handelt es sich?")
    }

    public static func signal(_ m: SignalMeasurement, tuning: AssistantTuning, image: Data?) -> AssistantContext {
        var text = "Zustand von Digidec:\n" + tuning.lines.joined(separator: "\n")
        text += "\n\nSignal im HF-Wasserfall (von Digidec gemessen):\n" + m.describe()
        let hints = SignalHints.candidates(m, tuning: tuning)
        if !hints.isEmpty {
            text += "\n\nAnhaltspunkte aus Digidecs eigenen Tabellen (Heuristik aus Tonabstand, Tastung, Breite und Frequenz, ohne Gewähr; mit den Messwerten gegenprüfen):\n" + hints.map { "- " + $0 }.joined(separator: "\n")
        }
        if image != nil { text += "\n\nBeigefügt ist der Wasserfall-Ausschnitt um das Signal (Frequenz waagerecht, Zeit senkrecht, neueste Zeile oben, Marke an der gemessenen Mitte)." }
        return AssistantContext(kind: .signal, title: "Signal bei " + AssistantFormat.frequency(m.centerHz), text: text, image: image,
                                suggestedQuestion: "Was für ein Signal ist das? Nenne die wahrscheinlichsten Verfahren oder Dienste mit Begründung und sag, was ich in Digidec zur Bestätigung ausprobieren kann.")
    }
}

public enum AssistantPrompt {
    /// Systemanweisung. `moduleNames`: die Decoder, die Digidec kennt (damit das Modell auf sie verweisen kann).
    public static func system(moduleNames: [String], language: String) -> String {
        let answer = language.hasPrefix("en") ? "Answer in English." : "Antworte auf Deutsch."
        return """
        Du bist ein erfahrener Assistent für Funkempfang und Signalerkennung in der Software Digidec (macOS, SDR-Empfänger und Decoder für Digimodes, Wetterfax, Flug- und Schiffsfunk und mehr). \
        Der Nutzer sieht ein Signal im Wasserfall oder einen decodierten Text, den er nicht zuordnen kann.
        Du bekommst Messwerte, die Digidec selbst am Signal bestimmt hat, bei Bedarf einen Wasserfall-Ausschnitt und den Zustand des Empfängers.
        Regeln:
        - \(answer) Kurz und sachlich, kein Smalltalk. Schlichte Formatierung: kurze Absätze und Aufzählungen mit „-“, Fettdruck mit ** ist erlaubt; keine Überschriften, keine Tabellen, keine Trennlinien.
        - Trenne Gemessenes von Vermutung. Nenne bei Vermutungen eine Wahrscheinlichkeit (hoch, mittel, gering) und die Begründung aus den Messwerten.
        - Gib mehrere Kandidaten an, wenn die Daten nicht eindeutig sind, der wahrscheinlichste zuerst.
        - Erfinde keine Frequenzlisten, Rufzeichen, Sendezeiten oder Standorte. Wenn du etwas nicht sicher weißt, sag es.
        - Sage, welche weitere Messung oder Einstellung die Frage klären würde (andere Bandbreite, anderes Modul, längere Beobachtung).
        - Verweise für eine Probe auf Module in Digidec. Digidec kennt: \(moduleNames.joined(separator: ", ")).
        - Die Anhaltspunkte aus Digidecs Tabellen sind Heuristik: bestätige oder widerlege sie anhand der Messwerte, übernimm sie nicht blind. Zahlen aus dem Kontext (Shift, Bandbreite, Frequenz) sind gemessen; nenne keine eigenen Zahlen, die dem widersprechen.
        - Beachte die Messgrenzen, die Digidec mitliefert (Frequenz- und Zeitauflösung); lies keine Feinheiten heraus, die nicht auflösbar sind.
        """
    }
}
