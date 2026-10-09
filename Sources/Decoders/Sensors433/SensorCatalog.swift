// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Alle Gerätedecoder der Funksensoren
public enum SensorCatalog {
    public static let all: [SensorDevice] = [
        // Abstandskodierung (PPM)
        SensorDevicesPPM.nexus, SensorDevicesPPM.nexusSauna, SensorDevicesPPM.prologue,
        SensorDevicesAcurite.th609, SensorDevicesAcurite.tx606, SensorDevicesTFA.twinPlus, SensorDevicesTFA.pool, SensorDevicesOregon.sl109h, SensorDevicesTFA.infactory,
        SensorDevicesMore.alecto, SensorDevicesMore.tx8300,
        // Pulsbreite (PWM)
        SensorDevicesFineOffset.wh2, SensorDevicesWH1080.ook, SensorDevicesMisc.lacrosseTX141, SensorDevicesTFA.tfa303221,
        SensorDevicesAcurite.tower, SensorDevicesEcowitt.wh53, SensorDevicesTFA.drop,
        // Manchester
        SensorDevicesOregon.oregon, SensorDevicesOregon.osv1, SensorDevicesMisc.hideki,
        // FSK
        SensorDevicesFineOffset.wh25, SensorDevicesWH1080.fsk, SensorDevicesBresser.fiveInOne, SensorDevicesBresser.sixInOne, SensorDevicesBresser.sevenInOne,
        SensorDevicesEcowitt.wh31, SensorDevicesTFA.tfa303196, SensorDevicesTFA.tfa141504, SensorDevicesTFA.marbella,
        SensorDevicesLaCrosseIT.tx29, SensorDevicesLaCrosseIT.tx35, SensorDevicesMore.tfa303151,
    ]

    /// Anzahl unterschiedlicher Gerätemodelle (Anzeige)
    public static let modelNames: [String] = all.map(\.name)
}
