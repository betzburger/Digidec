// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import VoiceCore
#if DIGIDEC_LOCAL_VOCODER
import LocalVocoder
#endif

/// Einstiegspunkt für Sprachdecoder, die nicht Teil des Repositorys sind: Wer sie lokal baut,
/// bekommt sie hier in `VoiceRegistry.shared` eingetragen. Ohne sie bleibt die Sammlung leer.
enum LocalVoiceHook {
    static func install() {
        #if DIGIDEC_LOCAL_VOCODER
        registerLocalVoiceDecoders(into: .shared)
        #endif
    }
}
