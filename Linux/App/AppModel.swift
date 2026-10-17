// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Observation
import Combine
@testable import DigidecCore

/// Brücke zwischen dem Zustand des Kerns (`DigidecState`, OpenCombine) und den Ansichten (SwiftCrossUI, `@Observable`).
/// Ansichten lesen `revision` im Aufbau; jede Änderung der beobachteten Objekte erhöht sie höchstens zehnmal je Sekunde.
@MainActor
@Observable
final class AppModel {
    let state = DigidecState.shared
    private(set) var revision = 0

    var palette: ThemePalette { ThemeModel.shared.palette }
    let ballistics = NeedleBallistics()

    @ObservationIgnored private var subscriptions: [AnyCancellable] = []
    @ObservationIgnored private var started = false

    init() {
        let s = state
        let triggers: [AnyPublisher<Void, Never>] = [
            s.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            s.audio.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            s.ft8.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            s.ft8Controller.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.bump() }
            .store(in: &subscriptions)
    }

    func bump() { revision &+= 1 }

    /// Beim ersten Aufbau des Fensters den Audio-Eingang starten (wie `onAppear { state.startAudio() }` am Mac)
    func startIfNeeded() {
        guard !started else { return }
        started = true
        GtkStyle.install(palette: palette)
        state.startAudio()
    }
}
