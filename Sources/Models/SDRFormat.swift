// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

enum SDRFormat {
    /// 145,500000 (MHz, sechs Nachkommastellen)
    static func frequency(_ hz: Double) -> String {
        String(format: "%.6f", hz / 1e6).replacingOccurrences(of: ".", with: ",")
    }

    static func stepName(_ hz: Double) -> String {
        if hz >= 1e6 { return String(format: "%g MHz", hz / 1e6).replacingOccurrences(of: ".", with: ",") }
        if hz >= 1000 { return String(format: "%g kHz", hz / 1000).replacingOccurrences(of: ".", with: ",") }
        return String(format: "%g Hz", hz)
    }
}
