import Foundation

/// Was die gemeinsame Textansicht (`TextModeReceivePanel`) von einem Controller braucht (PSK, Olivia, Contestia, MT63)
@MainActor
protocol TextModeController: ObservableObject {
    var textModel: ReceiveTextModel { get }
    var logger: DecodeLogger { get }
    var logEnabled: Bool { get set }
    var lastCharacterDate: Date? { get }
    func clearText()
}
