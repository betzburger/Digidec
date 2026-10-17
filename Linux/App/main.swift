// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
@testable import DigidecCore

// Linux-Frontend (Entwurf): zunächst nur ein Lebenszeichen des Kerns, die Oberfläche folgt.
print("Digidec \(AppVersion.short) (Linux)")
let inputs = AudioDeviceCatalog.inputDevices()
print("Audio-Eingänge: \(inputs.count)")
for device in inputs { print("  \(device.name) [\(device.inputChannels) Kanäle, \(Int(device.nominalSampleRate)) Hz]") }
