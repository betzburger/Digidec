// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Enthält das vollwertige RadioTheme Single-Page Web-Dashboard für entfernte Browser.
/// Wird direkt aus dem Speicher als UTF-8 ausgeliefert (ohne Datei-Abhängigkeiten).
public enum WebDashboardAssets {
    /// Raw-String, damit JS-Escapes wie `\n` unverändert beim Browser ankommen.
    public static let html: String = #"""
<!DOCTYPE html>
<html lang="de">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <title>Digidec · Web Remote Dashboard</title>
    <style>
        :root {
            --bg-deep: #0b0d0f;
            --bg-panel: #14181c;
            --bg-surface: #1a2026;
            --border-subtle: #242c34;
            --border-bright: #3a4754;
            --vfd-cyan: #00e5ff;
            --vfd-cyan-dim: #008899;
            --vfd-green: #00e676;
            --vfd-amber: #ffb300;
            --led-red: #ff3d00;
            --text-bright: #e6f0fa;
            --text-dim: #7890a8;
            --text-muted: #4a5d6e;
            --font-mono: "SF Mono", Menlo, Monaco, Consolas, "Liberation Mono", monospace;
        }

        * {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
            -webkit-user-select: none;
            user-select: none;
        }

        body {
            background-color: var(--bg-deep);
            color: var(--text-bright);
            font-family: var(--font-mono);
            font-size: 13px;
            display: flex;
            flex-direction: column;
            height: 100vh;
            height: 100dvh;
            overflow: hidden;
        }

        /* Top Bar */
        header {
            background: linear-gradient(180deg, #181d22 0%, #111418 100%);
            border-bottom: 1px solid var(--border-subtle);
            padding: 8px 14px;
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 12px;
            flex-shrink: 0;
            flex-wrap: wrap;
        }
        .brand { display: flex; align-items: baseline; gap: 8px; }
        .brand-title {
            font-size: 16px;
            font-weight: 900;
            letter-spacing: 1.5px;
            color: var(--vfd-cyan);
            text-shadow: 0 0 10px rgba(0, 229, 255, 0.4);
        }
        .brand-sub { font-size: 9px; font-weight: 700; color: var(--vfd-amber); letter-spacing: 1px; }
        .header-controls { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }

        .status-pill {
            display: flex;
            align-items: center;
            gap: 6px;
            background: var(--bg-deep);
            border: 1px solid var(--border-subtle);
            border-radius: 4px;
            padding: 4px 8px;
            font-size: 10px;
            font-weight: bold;
        }
        .status-dot {
            width: 7px; height: 7px; border-radius: 50%;
            background-color: var(--led-red);
            box-shadow: 0 0 6px var(--led-red);
        }
        .status-dot.connected { background-color: var(--vfd-green); box-shadow: 0 0 6px var(--vfd-green); }

        button {
            font-family: var(--font-mono);
            font-size: 10px;
            font-weight: bold;
            padding: 5px 10px;
            background: var(--bg-surface);
            color: var(--text-bright);
            border: 1px solid var(--border-bright);
            border-radius: 3px;
            cursor: pointer;
            transition: all 0.1s ease;
        }
        button:hover { background: #252e37; border-color: var(--vfd-cyan); }
        button:disabled { opacity: 0.4; cursor: default; }
        button:disabled:hover { background: var(--bg-surface); border-color: var(--border-bright); }
        button.active {
            background: var(--vfd-cyan);
            color: var(--bg-deep);
            border-color: var(--vfd-cyan);
            box-shadow: 0 0 8px rgba(0, 229, 255, 0.4);
        }
        button.small { padding: 2px 7px; font-size: 9px; }

        /* Module Bar */
        .module-bar {
            background: var(--bg-panel);
            border-bottom: 1px solid var(--border-subtle);
            padding: 6px 14px;
            display: flex;
            flex-direction: column;
            gap: 5px;
            overflow-y: auto;
            max-height: 26vh;
            flex-shrink: 0;
        }
        .module-bar::-webkit-scrollbar { width: 4px; }
        .module-bar::-webkit-scrollbar-thumb { background: var(--border-bright); border-radius: 2px; }
        .module-group { display: flex; align-items: flex-start; gap: 8px; }
        .module-group-label {
            flex: 0 0 56px;
            padding-top: 6px;
            font-size: 9px;
            font-weight: 900;
            letter-spacing: 0.8px;
            color: var(--group-color, var(--vfd-cyan));
        }
        .module-group-items { display: flex; flex-wrap: wrap; gap: 4px; }
        .module-group.hf { --group-color: var(--vfd-amber); }
        .module-group.vhf { --group-color: var(--vfd-green); }
        .module-btn { font-size: 10px; padding: 4px 8px; border-radius: 3px; }

        /* VFO / Frequenz */
        .vfo-strip {
            background: #0f1317;
            border-bottom: 1px solid var(--border-subtle);
            padding: 8px 14px;
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 10px 16px;
            flex-wrap: wrap;
            flex-shrink: 0;
        }
        .freq-display { display: flex; align-items: baseline; gap: 6px; }
        .freq-readout {
            font-size: 22px;
            font-weight: 900;
            color: var(--vfd-cyan);
            letter-spacing: 1px;
            text-shadow: 0 0 12px rgba(0, 229, 255, 0.5);
            cursor: text;
            min-width: 120px;
        }
        .freq-readout.fixed { cursor: default; }
        .freq-input {
            font-family: var(--font-mono);
            font-size: 20px;
            font-weight: 900;
            width: 170px;
            background: var(--bg-deep);
            color: var(--vfd-cyan);
            border: 1px solid var(--vfd-cyan);
            border-radius: 3px;
            padding: 0 6px;
            outline: none;
            -webkit-user-select: text;
            user-select: text;
        }
        .freq-unit { font-size: 11px; font-weight: bold; color: var(--text-dim); }
        .source-tag {
            font-size: 9px; font-weight: 700; letter-spacing: 0.5px; color: var(--vfd-green);
            border: 1px solid var(--border-subtle); border-radius: 3px; padding: 2px 6px; background: #0b0e12;
        }
        .mode-group { display: flex; align-items: center; gap: 3px; flex-wrap: wrap; }
        .mode-label { font-size: 11px; font-weight: bold; color: var(--vfd-amber); padding: 0 4px; }
        .tuning-controls { display: flex; align-items: center; gap: 4px; flex-wrap: wrap; }

        .preset-bar { display: flex; align-items: center; gap: 6px 10px; flex-wrap: wrap; }
        .preset-bar:empty { display: none; }
        .preset-item { display: flex; align-items: center; gap: 5px; }
        .preset-item label { font-size: 9px; font-weight: 900; letter-spacing: 0.8px; color: var(--vfd-amber); }
        .preset-item select { max-width: 260px; }
        .sdr-strip { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
        .sdr-select {
            font-family: var(--font-mono);
            font-size: 10px;
            font-weight: bold;
            padding: 4px 8px;
            background: var(--bg-surface);
            color: var(--text-bright);
            border: 1px solid var(--border-bright);
            border-radius: 3px;
            cursor: pointer;
            outline: none;
        }
        .sdr-select:focus { border-color: var(--vfd-cyan); }
        .sdr-status-badge {
            font-size: 10px;
            font-weight: 700;
            color: var(--text-dim);
            background: #0b0e12;
            border: 1px solid var(--border-subtle);
            border-radius: 3px;
            padding: 3px 8px;
            max-width: 240px;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
        }
        .sdr-status-badge.error { color: var(--led-red); border-color: var(--led-red); box-shadow: 0 0 6px rgba(255, 61, 0, 0.4); }
        .sdr-status-badge.active { color: var(--vfd-green); border-color: var(--vfd-green); }

        /* Arbeitsbereich */
        main { display: flex; flex-direction: column; flex: 1; min-height: 0; position: relative; }

        /* Wasserfall */
        .wf-panel { flex: 0 0 auto; display: flex; flex-direction: column; background: var(--bg-panel); }
        .wf-bar {
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 8px 12px;
            flex-wrap: wrap;
            padding: 4px 12px;
            background: #111519;
            border-bottom: 1px solid var(--border-subtle);
            font-size: 10px;
            font-weight: bold;
        }
        .wf-title { color: var(--text-dim); letter-spacing: 0.5px; }
        .wf-readout { color: var(--text-muted); flex: 1; text-align: center; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-width: 0; }
        .wf-tools { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
        .zoom-group, .dyn-group { display: flex; align-items: center; gap: 3px; }
        .dyn-group span { color: var(--text-dim); font-size: 9px; }
        .dyn-group .val { color: var(--vfd-cyan); min-width: 40px; text-align: center; font-size: 10px; }

        .wf-stack {
            position: relative;
            height: 200px;
            min-height: 90px;
            max-height: 75vh;
            background: #000;
            display: flex;
            flex-direction: column;
            overflow: hidden;
            touch-action: none;
        }
        #axis-canvas { flex: 0 0 18px; width: 100%; height: 18px; display: block; background: var(--bg-panel); }
        #spec-canvas { flex: 0 0 54px; width: 100%; height: 54px; display: block; background: var(--bg-deep); border-bottom: 1px solid var(--border-subtle); }
        #waterfall-canvas { flex: 1 1 auto; width: 100%; min-height: 0; display: block; background: #000; }
        #mark-canvas { position: absolute; left: 0; right: 0; top: 18px; bottom: 0; width: 100%; height: calc(100% - 18px); cursor: crosshair; }
        .wf-note {
            position: absolute; left: 0; right: 0; top: 50%;
            transform: translateY(-50%);
            text-align: center; padding: 0 16px;
            font-size: 10px; font-weight: 700; letter-spacing: 1.2px;
            color: var(--text-dim);
            pointer-events: none;
            text-shadow: 0 1px 2px #000;
        }
        .wf-note.error { color: var(--vfd-amber); }
        .wf-stack.none #axis-canvas, .wf-stack.none #spec-canvas, .wf-stack.none #mark-canvas { display: none; }
        .wf-stack.none { height: 56px !important; min-height: 56px; }

        /* Trennbalken */
        .splitter {
            height: 8px;
            background: var(--bg-surface);
            border-top: 1px solid var(--border-subtle);
            border-bottom: 1px solid var(--border-subtle);
            cursor: row-resize;
            flex-shrink: 0;
            display: flex;
            align-items: center;
            justify-content: center;
            touch-action: none;
            transition: background 0.15s ease, border-color 0.15s ease;
        }
        .splitter:hover, .splitter.dragging { background: #1c2633; border-color: var(--vfd-cyan); }
        .splitter::after { content: ""; width: 36px; height: 2px; background: #3a4d65; border-radius: 1px; }
        .splitter:hover::after, .splitter.dragging::after { background: var(--vfd-cyan); }

        /* Ausgabe */
        .output-panel { flex: 1; min-height: 120px; background: var(--bg-panel); display: flex; flex-direction: column; overflow: hidden; }
        .output-header {
            background: #111519;
            border-bottom: 1px solid var(--border-subtle);
            padding: 4px 12px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            gap: 8px;
            font-size: 10px;
            font-weight: bold;
            color: var(--text-dim);
        }
        #terminal-title { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        #terminal {
            flex: 1;
            padding: 10px;
            background: #0d1013;
            color: var(--vfd-cyan);
            font-size: 12px;
            line-height: 1.4;
            overflow: auto;
            white-space: pre;
            -webkit-user-select: text;
            user-select: text;
        }
        #terminal.log { white-space: pre-wrap; word-break: break-word; }
        #terminal .empty { color: var(--text-muted); }
        .view-tabs { display: flex; gap: 4px; align-items: center; }
        .view-tabs .sep { width: 8px; }

        /* Karte */
        #map-wrap {
            flex: 1; min-height: 0; position: relative; display: none;
            background: #0b0d0f; overflow: hidden; touch-action: none; cursor: grab;
        }
        #map-wrap.dragging { cursor: grabbing; }
        #map-tiles { position: absolute; inset: 0; overflow: hidden; }
        #map-tiles img { position: absolute; width: 256px; height: 256px; max-width: none; -webkit-user-drag: none; pointer-events: none; }
        #map-wrap.dark #map-tiles { filter: invert(1) hue-rotate(180deg) brightness(0.82) contrast(0.9) saturate(0.55); }
        #map-canvas { position: absolute; inset: 0; width: 100%; height: 100%; }
        .map-btns { position: absolute; top: 8px; right: 8px; display: flex; flex-direction: column; gap: 4px; }
        .map-btns button { min-width: 30px; background: rgba(20, 24, 28, 0.88); }
        .map-attrib { position: absolute; right: 0; bottom: 0; padding: 1px 6px; font-size: 9px; background: rgba(11, 13, 15, 0.75); color: var(--text-dim); }
        .map-attrib a { color: var(--vfd-cyan-dim); text-decoration: none; }
        .map-hint {
            position: absolute; left: 50%; top: 12px; transform: translateX(-50%);
            padding: 4px 10px; font-size: 10px; font-weight: bold; color: var(--vfd-amber);
            background: rgba(11, 13, 15, 0.85); border: 1px solid var(--border-subtle); border-radius: 4px;
            pointer-events: none; white-space: nowrap; max-width: 80%; overflow: hidden; text-overflow: ellipsis;
        }
        .map-popup {
            position: absolute; left: 8px; bottom: 18px; max-width: min(360px, 70%); max-height: 55%;
            overflow-y: auto; padding: 8px 10px; font-size: 11px; line-height: 1.4;
            background: rgba(20, 24, 28, 0.94); border: 1px solid var(--vfd-cyan-dim); border-radius: 5px;
            display: none; -webkit-user-select: text; user-select: text;
        }
        .map-popup .pt { color: var(--vfd-cyan); font-weight: 900; font-size: 12px; }
        .map-popup .ps { color: var(--vfd-amber); font-size: 10px; margin-bottom: 3px; }
        .map-popup .pd { color: var(--text-bright); }

        /* Audio */
        .audio-bar { display: flex; align-items: center; gap: 8px; }
        .vol-slider { width: 70px; height: 4px; accent-color: var(--vfd-cyan); }
        .audio-info { font-size: 9px; color: var(--text-muted); min-width: 64px; }

        footer {
            background: #0f1215;
            border-top: 1px solid var(--border-subtle);
            padding: 4px 14px;
            font-size: 10px;
            color: var(--text-dim);
            display: flex;
            justify-content: space-between;
            align-items: center;
            gap: 10px;
            flex-shrink: 0;
        }
        footer span { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }

        @media (max-width: 700px) {
            .module-group-label { flex-basis: 44px; }
            .freq-readout { font-size: 18px; }
        }
    </style>
</head>
<body>
    <header>
        <div class="brand">
            <span class="brand-title">DIGIDEC</span>
            <span class="brand-sub">WEB REMOTE</span>
        </div>
        <div class="header-controls">
            <div class="status-pill">
                <div id="ws-dot" class="status-dot"></div>
                <span id="ws-status">OFFLINE</span>
            </div>
            <div class="audio-bar">
                <button id="btn-audio" onclick="toggleAudio()" title="Ton des Empfängers im Browser wiedergeben">AUDIO: AUS</button>
                <input id="vol-slider" class="vol-slider" type="range" min="0" max="1" step="0.05" value="0.8" oninput="setVolume(this.value)" title="Lautstärke">
                <span id="audio-info" class="audio-info"></span>
            </div>
        </div>
    </header>

    <div id="module-bar" class="module-bar"></div>

    <div class="vfo-strip">
        <div class="freq-display">
            <span id="freq-val" class="freq-readout fixed" onclick="editFrequency()" title="Frequenz eingeben (MHz; mit k hinten in kHz)">---</span>
            <span id="freq-unit" class="freq-unit">MHz</span>
            <span id="source-tag" class="source-tag" style="display:none"></span>
        </div>
        <div id="mode-group" class="mode-group"></div>
        <div id="preset-bar" class="preset-bar"></div>
        <div class="tuning-controls">
            <button class="tune-btn" onclick="tuneOffset(-100000)">-100 kHz</button>
            <button class="tune-btn" onclick="tuneOffset(-1000)">-1 kHz</button>
            <button class="tune-btn" onclick="tuneOffset(-100)">-100 Hz</button>
            <button class="tune-btn" onclick="tuneOffset(100)">+100 Hz</button>
            <button class="tune-btn" onclick="tuneOffset(1000)">+1 kHz</button>
            <button class="tune-btn" onclick="tuneOffset(100000)">+100 kHz</button>
        </div>
        <div class="sdr-strip">
            <button id="btn-sdr" onclick="toggleSDR()" title="SDR-Empfänger ein- oder ausschalten">SDR: AUS</button>
            <select id="sel-sdr-src" class="sdr-select" onchange="selectSDRSource(this.value)" title="SDR-Gerät wählen">
                <option value="hackrf">HackRF</option>
                <option value="rtlsdr">RTL-SDR</option>
                <option value="sdrplay">SDRplay</option>
                <option value="sdrconnect">SDRconnect</option>
            </select>
            <button id="btn-wf-mode" onclick="toggleWaterfallMode()" title="Zwischen NF-Audio und HF-Spektrum umschalten">WASSERFALL: NF</button>
            <div id="sdr-badge" class="sdr-status-badge">Audio</div>
        </div>
    </div>

    <main>
        <section class="wf-panel">
            <div class="wf-bar">
                <span id="wf-title" class="wf-title">NF-WASSERFALL</span>
                <span id="wf-readout" class="wf-readout"></span>
                <div class="wf-tools">
                    <span id="wf-zooms" class="zoom-group"></span>
                    <span class="dyn-group">
                        <span>DYN</span>
                        <button class="small" onclick="wfRange(5)" title="Kontrast verringern (größerer Dynamikbereich)">&minus;</button>
                        <span id="wf-range" class="val">50 dB</span>
                        <button class="small" onclick="wfRange(-5)" title="Kontrast erhöhen (kleinerer Dynamikbereich)">+</button>
                    </span>
                </div>
            </div>
            <div id="wf-stack" class="wf-stack">
                <canvas id="axis-canvas"></canvas>
                <canvas id="spec-canvas"></canvas>
                <canvas id="waterfall-canvas"></canvas>
                <canvas id="mark-canvas"></canvas>
                <div id="wf-note" class="wf-note"></div>
            </div>
        </section>
        <div id="splitter" class="splitter" title="Ziehen zum Einstellen der Höhe"></div>
        <div class="output-panel">
            <div class="output-header">
                <span id="terminal-title">EMPFANGSTEXT</span>
                <div class="view-tabs">
                    <button id="tab-text" class="active" onclick="setView('text')">TEXT</button>
                    <button id="tab-map" onclick="setView('map')">KARTE</button>
                    <span class="sep"></span>
                    <button id="btn-clear" onclick="clearTerminal()">LEEREN</button>
                </div>
            </div>
            <div id="terminal"><span class="empty">Warten auf Verbindung zum Digidec Host-Server...</span></div>
            <div id="map-wrap" class="dark">
                <div id="map-tiles"></div>
                <canvas id="map-canvas"></canvas>
                <div id="map-hint" class="map-hint" style="display:none"></div>
                <div class="map-btns">
                    <button onclick="mapZoom(1)" title="Vergrößern">+</button>
                    <button onclick="mapZoom(-1)" title="Verkleinern">&minus;</button>
                    <button onclick="mapFit()" title="Auf alle Punkte zoomen">&#9678;</button>
                    <button id="btn-map-style" onclick="toggleMapStyle()" title="Dunkle oder helle Karte">DUNKEL</button>
                </div>
                <div id="map-popup" class="map-popup"></div>
                <div class="map-attrib">&copy; <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">OpenStreetMap</a>-Mitwirkende</div>
            </div>
        </div>
    </main>

    <footer>
        <span id="rig-status">Funkgerät: --</span>
        <span id="client-info">Digidec WebEngine · RadioTheme</span>
    </footer>

    <script>
        "use strict";
        let ws = null;
        let audioCtx = null;
        let audioGain = null;
        let audioRunning = false;
        let nextAudioTime = 0;
        let audioRate = 0;
        let currentModule = "";
        let currentView = "text"; // "text" oder "map"
        let knownModules = [];
        let shapes = {};
        let sdrEnabled = false;
        let isRFMode = false;
        let state = { dialHz: 0, mode: "", modes: [], freqEditable: false, source: "" };

        const $ = (id) => document.getElementById(id);
        const send = (obj) => { if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj)); };

        // ---------------------------------------------------------------------
        // RadioTheme-Farbtabelle (wie WaterfallColorMap der App)
        // ---------------------------------------------------------------------
        const lut = new Uint32Array(256);
        (function buildLUT() {
            const stops = [
                [0.00, 0.07, 0.08, 0.10], [0.20, 0.05, 0.18, 0.40], [0.40, 0.00, 0.60, 0.85], [0.55, 0.00, 0.90, 1.00],
                [0.70, 0.00, 0.95, 0.45], [0.82, 1.00, 0.72, 0.10], [0.93, 1.00, 0.20, 0.30], [1.00, 1.00, 0.95, 0.95]
            ];
            for (let i = 0; i < 256; i++) {
                const x = i / 255;
                let u = stops.findIndex(s => s[0] >= x);
                if (u < 0) u = stops.length - 1;
                const l = Math.max(0, u - 1);
                const a = stops[l], b = stops[u];
                const t = b[0] > a[0] ? (x - a[0]) / (b[0] - a[0]) : 0;
                const ch = (k) => Math.round((a[k] + (b[k] - a[k]) * t) * 255);
                lut[i] = (255 << 24) | (ch(3) << 16) | (ch(2) << 8) | ch(1);
            }
        })();

        // ---------------------------------------------------------------------
        // Wasserfall: Zeilen mit eigenem Frequenzbereich, Ansicht mit Skala, Spektrum und Marken
        // ---------------------------------------------------------------------
        let wf = { kind: "none", visLo: 0, visHi: 4000, fullLo: 0, fullHi: 4000, center: 0, bw: 0, style: "none", zoom: 1, zoomChoices: [], range: 50, tunable: false, channels: [] };
        let rowsHistory = [];          // neueste zuerst: { lo, hi, d }
        const axisCv = $("axis-canvas"), specCv = $("spec-canvas"), wfCv = $("waterfall-canvas"), markCv = $("mark-canvas");
        const axisCtx = axisCv.getContext("2d"), specCtx = specCv.getContext("2d"), wfCtx = wfCv.getContext("2d"), markCtx = markCv.getContext("2d");
        let wfImg = null, wfBuf = null, wfW = 0, wfH = 0, dpr = 1;
        let hoverF = null;

        function resizeWF() {
            dpr = Math.max(1, Math.min(2, window.devicePixelRatio || 1));
            const rect = wfCv.getBoundingClientRect();
            const w = Math.floor(rect.width), h = Math.floor(rect.height);
            if (w > 0 && h > 0 && (w !== wfW || h !== wfH)) {
                wfW = w; wfH = h;
                wfCv.width = w; wfCv.height = h;
                wfImg = wfCtx.createImageData(w, h);
                wfBuf = new Uint32Array(wfImg.data.buffer);
                wfBuf.fill(lut[0]);
                renderAllRows();
            }
            for (const [cv, h2] of [[axisCv, 18], [specCv, 54]]) {
                const cw = Math.floor(cv.getBoundingClientRect().width);
                if (cw > 0 && (cv.width !== cw * dpr || cv.height !== h2 * dpr)) { cv.width = cw * dpr; cv.height = h2 * dpr; }
            }
            const mr = markCv.getBoundingClientRect();
            if (mr.width > 0 && (markCv.width !== Math.floor(mr.width * dpr) || markCv.height !== Math.floor(mr.height * dpr))) {
                markCv.width = Math.floor(mr.width * dpr); markCv.height = Math.floor(mr.height * dpr);
            }
            drawAxis(); drawMarks(); drawSpectrum();
        }
        window.addEventListener("resize", () => { resizeWF(); resizeMapCanvas(); renderMap(); });
        if (window.ResizeObserver) new ResizeObserver(resizeWF).observe($("wf-stack"));
        setTimeout(resizeWF, 50);

        /** Eine Zeile auf Pixelspalten der aktuellen Ansicht abbilden (Maximum je Spalte; bei grober Auflösung interpoliert) */
        function mapRow(row, out) {
            const W = out.length, n = row.d.length;
            const span = wf.visHi - wf.visLo, rs = row.hi - row.lo;
            if (span <= 0 || rs <= 0 || n === 0) { out.fill(lut[0]); return; }
            const bpHz = n / rs;
            for (let x = 0; x < W; x++) {
                const f0 = wf.visLo + (x / W) * span, f1 = wf.visLo + ((x + 1) / W) * span;
                if (f1 < row.lo || f0 > row.hi) { out[x] = lut[0]; continue; }
                let i0 = Math.floor((Math.max(f0, row.lo) - row.lo) * bpHz);
                let i1 = Math.ceil((Math.min(f1, row.hi) - row.lo) * bpHz);
                if (i0 < 0) i0 = 0;
                if (i1 > n) i1 = n;
                if (i1 - i0 <= 1) {
                    const p = ((f0 + f1) / 2 - row.lo) * bpHz - 0.5;
                    const i = Math.max(0, Math.min(n - 1, Math.floor(p)));
                    const j = Math.min(n - 1, i + 1);
                    const t = Math.max(0, Math.min(1, p - i));
                    out[x] = lut[Math.round(row.d[i] * (1 - t) + row.d[j] * t)];
                } else {
                    let m = 0;
                    for (let i = i0; i < i1; i++) if (row.d[i] > m) m = row.d[i];
                    out[x] = lut[m];
                }
            }
        }

        function renderAllRows() {
            if (!wfBuf) return;
            wfBuf.fill(lut[0]);
            const n = Math.min(rowsHistory.length, wfH);
            for (let r = 0; r < n; r++) mapRow(rowsHistory[r], wfBuf.subarray(r * wfW, (r + 1) * wfW));
            wfCtx.putImageData(wfImg, 0, 0);
        }

        function onRow(kind, lo, hi, d) {
            const k = kind === 1 ? "rf" : "af";
            if (k !== wf.kind) return;
            const row = { lo, hi, d };
            rowsHistory.unshift(row);
            if (rowsHistory.length > 600) rowsHistory.length = 600;
            if (!wfBuf) return;
            wfBuf.copyWithin(wfW, 0, wfW * (wfH - 1));
            mapRow(row, wfBuf.subarray(0, wfW));
            wfCtx.putImageData(wfImg, 0, 0);
            drawSpectrum();
        }

        function fmtMHz(hz, dec) { return (hz / 1e6).toFixed(dec).replace(".", ","); }

        function drawAxis() {
            const w = axisCv.width, h = axisCv.height;
            axisCtx.clearRect(0, 0, w, h);
            axisCtx.fillStyle = "#14181c";
            axisCtx.fillRect(0, 0, w, h);
            const span = wf.visHi - wf.visLo;
            if (wf.kind === "none" || span <= 0) return;
            const rf = wf.kind === "rf";
            let step;
            if (rf) {
                const steps = [500, 1e3, 2e3, 5e3, 1e4, 2e4, 5e4, 1e5, 2e5, 5e5, 1e6, 2e6, 5e6];
                step = steps.find(s => span / s <= 12) || 2e6;
            } else {
                step = span > 2500 ? 500 : span > 1200 ? 200 : span > 600 ? 100 : 50;
            }
            axisCtx.font = "600 " + Math.round(8.5 * dpr) + "px " + getComputedStyle(document.body).fontFamily;
            axisCtx.textAlign = "center";
            axisCtx.textBaseline = "middle";
            let f = Math.ceil(wf.visLo / step) * step;
            for (; f <= wf.visHi; f += step) {
                const x = ((f - wf.visLo) / span) * w;
                axisCtx.fillStyle = "#7890a8";
                axisCtx.fillRect(Math.round(x), h - 4 * dpr, Math.max(1, dpr), 4 * dpr);
                let label;
                if (!rf) label = String(Math.round(f));
                else if (step >= 1e6) label = (f / 1e6).toFixed(0);
                else if (step >= 1e5) label = fmtMHz(f, 1);
                else if (step >= 1e4) label = fmtMHz(f, 2);
                else if (step >= 1e3) label = fmtMHz(f, 3);
                else label = fmtMHz(f, 4);
                axisCtx.fillStyle = "#4a5d6e";
                axisCtx.fillText(label, Math.min(Math.max(x, 18 * dpr), w - 18 * dpr), 7 * dpr);
            }
        }

        function drawSpectrum() {
            const w = specCv.width, h = specCv.height;
            specCtx.clearRect(0, 0, w, h);
            const row = rowsHistory[0];
            if (!row || wf.kind === "none") return;
            const cols = Math.max(2, Math.floor(w / dpr));
            const out = new Uint32Array(cols);   // nur zur Abbildung: Index statt Farbe
            const span = wf.visHi - wf.visLo, rs = row.hi - row.lo, n = row.d.length;
            if (span <= 0 || rs <= 0) return;
            const bpHz = n / rs;
            specCtx.beginPath();
            let started = false, lastX = 0;
            for (let x = 0; x < cols; x++) {
                const f0 = wf.visLo + (x / cols) * span, f1 = wf.visLo + ((x + 1) / cols) * span;
                if (f1 < row.lo || f0 > row.hi) continue;
                let i0 = Math.max(0, Math.floor((Math.max(f0, row.lo) - row.lo) * bpHz));
                let i1 = Math.min(n, Math.ceil((Math.min(f1, row.hi) - row.lo) * bpHz));
                let v = 0;
                if (i1 - i0 <= 1) {
                    const p = ((f0 + f1) / 2 - row.lo) * bpHz - 0.5;
                    const i = Math.max(0, Math.min(n - 1, Math.floor(p)));
                    const j = Math.min(n - 1, i + 1);
                    const t = Math.max(0, Math.min(1, p - i));
                    v = row.d[i] * (1 - t) + row.d[j] * t;
                } else {
                    for (let i = i0; i < i1; i++) if (row.d[i] > v) v = row.d[i];
                }
                const px = (x / (cols - 1)) * w, py = h - 2 * dpr - (v / 255) * (h - 6 * dpr);
                if (!started) { specCtx.moveTo(px, py); started = true; } else specCtx.lineTo(px, py);
                lastX = px;
            }
            if (!started) return;
            specCtx.strokeStyle = "#00e676";
            specCtx.lineWidth = dpr;
            specCtx.stroke();
            specCtx.lineTo(lastX, h);
            specCtx.lineTo(0, h);
            specCtx.closePath();
            specCtx.fillStyle = "rgba(0, 230, 118, 0.12)";
            specCtx.fill();
        }

        function fx(f) {   // Frequenz → x in Bildpunkten des Marken-Canvas
            return ((f - wf.visLo) / (wf.visHi - wf.visLo)) * markCv.width;
        }

        function drawMarks() {
            const w = markCv.width, h = markCv.height;
            markCtx.clearRect(0, 0, w, h);
            if (wf.kind === "none" || wf.visHi <= wf.visLo) return;
            const mono = getComputedStyle(document.body).fontFamily;
            const line = (x, color, dash, label, y0) => {
                if (x < 0 || x > w) return;
                markCtx.beginPath();
                markCtx.moveTo(x, y0 || 0); markCtx.lineTo(x, h);
                markCtx.strokeStyle = color; markCtx.lineWidth = dpr;
                markCtx.setLineDash(dash ? [3 * dpr, 3 * dpr] : []);
                markCtx.stroke(); markCtx.setLineDash([]);
                if (label) {
                    markCtx.fillStyle = color;
                    markCtx.font = "900 " + Math.round(9 * dpr) + "px " + mono;
                    markCtx.textAlign = "center"; markCtx.textBaseline = "top";
                    markCtx.fillText(label, Math.min(Math.max(x, 24 * dpr), w - 24 * dpr), 2 * dpr);
                }
            };
            const band = (color) => {
                if (wf.bw > 0) {
                    const x0 = fx(wf.center - wf.bw / 2), x1 = fx(wf.center + wf.bw / 2);
                    markCtx.fillStyle = color;
                    markCtx.fillRect(x0, 0, Math.max(dpr, x1 - x0), h);
                }
            };
            if (wf.style === "tones") {
                band("rgba(0, 229, 255, 0.07)");
                if (wf.mark !== undefined) line(fx(wf.mark), "rgba(255, 179, 0, 0.85)", true, "M", 12 * dpr);
                if (wf.space !== undefined) line(fx(wf.space), "rgba(0, 229, 255, 0.85)", true, "S", 12 * dpr);
            } else if (wf.style === "band") {
                band("rgba(0, 229, 255, 0.07)");
            } else if (wf.style === "dial") {
                if (wf.bandLo !== undefined && wf.bandHi !== undefined) {
                    // Durchlassbereich wie in der App: USB nur oberhalb, LSB nur unterhalb der Frequenz
                    const x0 = fx(wf.bandLo), x1 = fx(wf.bandHi);
                    markCtx.fillStyle = "rgba(0, 229, 255, 0.14)";
                    markCtx.fillRect(x0, 0, Math.max(2 * dpr, x1 - x0), h);
                } else band("rgba(0, 229, 255, 0.10)");
                line(fx(wf.center), "rgba(255, 179, 0, 0.95)", false, "", 0);
            } else if (wf.style === "channels" && wf.channels) {
                wf.channels.forEach((c, i) => {
                    const color = c.sel ? "#ffb300" : c.act ? "#00e676" : "#4a5d6e";
                    const x = fx(c.f);
                    if (x < 0 || x > w) return;
                    markCtx.beginPath(); markCtx.moveTo(x, 12 * dpr); markCtx.lineTo(x, h);
                    markCtx.strokeStyle = color; markCtx.lineWidth = c.sel ? 1.6 * dpr : dpr;
                    markCtx.setLineDash(c.sel ? [] : [3 * dpr, 3 * dpr]); markCtx.stroke(); markCtx.setLineDash([]);
                    markCtx.fillStyle = color; markCtx.font = "900 " + Math.round(8.5 * dpr) + "px " + mono;
                    markCtx.textAlign = "center"; markCtx.textBaseline = "top";
                    markCtx.fillText(c.label || String(Math.round(c.f)), Math.min(Math.max(x, 22 * dpr), w - 22 * dpr), (2 + (i % 2) * 9) * dpr);
                });
            }
            if (hoverF !== null) line(fx(hoverF), "rgba(230, 240, 250, 0.4)", false, "", 0);
        }

        function formatHover(f) {
            return wf.kind === "rf" ? "▸ " + fmtMHz(f, 6) + " MHz" : "▸ " + Math.round(f) + " Hz";
        }

        function updateWfReadout() {
            let s = wf.markerText || "";
            if (wf.kind === "rf") {
                const span = wf.visHi - wf.visLo;
                if (wf.zoom > 1) s += " · Span " + (span >= 1e6 ? (span / 1e6).toFixed(2).replace(".", ",") + " MHz" : (span / 1e3).toFixed(0) + " kHz");
            }
            if (hoverF !== null && wf.kind !== "none") s += (s ? " · " : "") + formatHover(hoverF);
            $("wf-readout").textContent = s;
        }

        // Klick oder Ziehen: Abstimmen (RF: gehörte Frequenz, NF: Mitte des Decoders)
        (function initMarkInput() {
            let dragging = false, lastSend = 0;
            const freqAt = (e) => {
                const r = markCv.getBoundingClientRect();
                const x = Math.max(0, Math.min(r.width, e.clientX - r.left));
                return wf.visLo + (x / Math.max(1, r.width)) * (wf.visHi - wf.visLo);
            };
            const tune = (e, force) => {
                if (!wf.tunable) return;
                const now = performance.now();
                if (!force && now - lastSend < 70) return;
                lastSend = now;
                send({ cmd: "setCenter", hz: freqAt(e) });
            };
            markCv.addEventListener("pointerdown", (e) => { dragging = true; markCv.setPointerCapture(e.pointerId); tune(e, true); });
            markCv.addEventListener("pointermove", (e) => {
                hoverF = freqAt(e);
                if (dragging) tune(e, false);
                drawMarks(); updateWfReadout();
            });
            const end = (e) => { if (dragging) { dragging = false; tune(e, true); } };
            markCv.addEventListener("pointerup", end);
            markCv.addEventListener("pointercancel", () => { dragging = false; });
            markCv.addEventListener("pointerleave", () => { hoverF = null; drawMarks(); updateWfReadout(); });
            // Mausrad: HF-Zoom (nur HF-Wasserfall)
            markCv.addEventListener("wheel", (e) => {
                if (wf.kind !== "rf" || !wf.zoomChoices.length) return;
                e.preventDefault();
                const vals = wf.zoomChoices.map(z => z.value);
                const i = vals.indexOf(wf.zoom);
                const next = vals[Math.max(0, Math.min(vals.length - 1, i + (e.deltaY < 0 ? 1 : -1)))];
                if (next !== wf.zoom) send({ cmd: "setRFZoom", zoom: next });
            }, { passive: false });
        })();

        function applyWfInfo(m) {
            const prevKind = wf.kind;
            const rangeChanged = m.visLo !== wf.visLo || m.visHi !== wf.visHi;
            wf = Object.assign({}, m);
            if (!wf.channels) wf.channels = [];
            if (m.kind !== prevKind) { rowsHistory = []; if (wfBuf) { wfBuf.fill(lut[0]); wfCtx.putImageData(wfImg, 0, 0); } }
            $("wf-stack").classList.toggle("none", wf.kind === "none");
            $("wf-title").textContent = wf.title || "";
            $("wf-range").textContent = wf.range + " dB";
            const note = $("wf-note");
            note.textContent = wf.note || "";
            note.className = "wf-note" + (wf.kind === "rf" && wf.note ? " error" : "");
            const zg = $("wf-zooms");
            const sig = wf.zoomChoices.map(z => z.label + z.value).join("|") + "@" + wf.zoom + wf.kind;
            if (zg.dataset.sig !== sig) {
                zg.dataset.sig = sig;
                zg.innerHTML = "";
                wf.zoomChoices.forEach(z => {
                    const b = document.createElement("button");
                    b.className = "small" + (z.value === wf.zoom ? " active" : "");
                    b.textContent = z.label;
                    b.title = wf.kind === "rf" ? "HF-Zoom " + z.label + (z.value === 1 ? " (gesamtes I/Q-Fenster)" : " um die Abstimmfrequenz") : "Angezeigter Bereich: " + z.label;
                    b.onclick = () => send({ cmd: wf.kind === "rf" ? "setRFZoom" : "setNFSpan", zoom: z.value, hz: z.value });
                    zg.appendChild(b);
                });
            }
            if (rangeChanged || m.kind !== prevKind) renderAllRows();
            drawAxis(); drawMarks(); drawSpectrum(); updateWfReadout();
        }

        function wfRange(delta) { send({ cmd: "setRange", delta }); }

        // Trennbalken: Höhe des Wasserfalls, wird gemerkt
        (function initSplitter() {
            const splitter = $("splitter"), stack = $("wf-stack");
            let saved = null;
            try { saved = parseInt(localStorage.getItem("digidec_wf_height2"), 10); } catch (e) {}
            if (saved >= 90 && saved <= 800) stack.style.height = saved + "px";
            let dragging = false, startY = 0, startH = 0;
            splitter.addEventListener("pointerdown", (e) => {
                dragging = true; startY = e.clientY; startH = stack.getBoundingClientRect().height;
                splitter.classList.add("dragging"); splitter.setPointerCapture(e.pointerId); e.preventDefault();
            });
            splitter.addEventListener("pointermove", (e) => {
                if (!dragging) return;
                const maxH = window.innerHeight - 260;
                stack.style.height = Math.max(90, Math.min(maxH, startH + e.clientY - startY)) + "px";
                resizeWF();
            });
            const stop = () => {
                if (!dragging) return;
                dragging = false; splitter.classList.remove("dragging");
                try { localStorage.setItem("digidec_wf_height2", Math.round(stack.getBoundingClientRect().height)); } catch (e) {}
                resizeWF();
            };
            splitter.addEventListener("pointerup", stop);
            splitter.addEventListener("pointercancel", stop);
        })();

        // ---------------------------------------------------------------------
        // Modulleiste
        // ---------------------------------------------------------------------
        function renderModuleBar(modules) {
            knownModules = modules;
            const bar = $("module-bar");
            bar.innerHTML = "";
            const groups = {};
            modules.forEach(m => { (groups[m.group || "HF"] = groups[m.group || "HF"] || []).push(m); });
            ["HF", "VHF/UHF"].forEach(gKey => {
                if (!groups[gKey] || groups[gKey].length === 0) return;
                const gDiv = document.createElement("div");
                gDiv.className = "module-group " + (gKey === "HF" ? "hf" : "vhf");
                const lbl = document.createElement("div");
                lbl.className = "module-group-label";
                lbl.textContent = gKey;
                gDiv.appendChild(lbl);
                const items = document.createElement("div");
                items.className = "module-group-items";
                groups[gKey].forEach(m => {
                    const btn = document.createElement("button");
                    btn.className = "module-btn" + (m.id === currentModule ? " active" : "");
                    btn.id = "mod-" + m.id;
                    btn.textContent = m.name;
                    btn.title = m.hasMap ? m.name + " (mit Karte)" : m.name;
                    btn.onclick = () => selectModule(m.id);
                    items.appendChild(btn);
                });
                gDiv.appendChild(items);
                bar.appendChild(gDiv);
            });
        }

        // ---------------------------------------------------------------------
        // Text und Karte (Reiter)
        // ---------------------------------------------------------------------
        let textLines = [], textKind = "log", textModule = "", clearedAt = 0, renderQueued = false;

        function setView(v) {
            currentView = v;
            const isMap = v === "map";
            $("tab-map").classList.toggle("active", isMap);
            $("tab-text").classList.toggle("active", !isMap);
            $("terminal").style.display = isMap ? "none" : "block";
            $("map-wrap").style.display = isMap ? "block" : "none";
            $("btn-clear").style.display = isMap ? "none" : "";
            send({ cmd: "setMap", enabled: isMap });
            if (isMap) setTimeout(() => { resizeMapCanvas(); renderMap(); }, 20);
        }

        let pendingReset = false;

        function applyText(m) {
            if (m.module !== textModule) { textLines = []; clearedAt = 0; textModule = m.module; pendingReset = true; }
            const from = Math.max(0, Math.min(m.from, textLines.length));
            textLines.length = from;
            for (const l of m.lines) textLines.push(l);
            textKind = m.kind;
            if (m.title) $("terminal-title").textContent = m.title.toUpperCase();
            if (clearedAt > textLines.length) clearedAt = 0;
            scheduleRenderText();
        }

        function scheduleRenderText() {
            if (renderQueued) return;
            renderQueued = true;
            requestAnimationFrame(() => { renderQueued = false; renderText(); });
        }

        function renderText() {
            const term = $("terminal");
            const nearBottom = term.scrollHeight - term.scrollTop - term.clientHeight < 40;
            const shown = textLines.slice(clearedAt);
            term.className = textKind === "log" ? "log" : "list";
            if (shown.length === 0) {
                term.innerHTML = '<span class="empty">Noch nichts empfangen</span>';
            } else {
                term.textContent = shown.join("\n");
            }
            if (pendingReset) {
                term.scrollTop = textKind === "log" ? term.scrollHeight : 0;
                term.scrollLeft = 0;
            } else if (textKind === "log" && nearBottom) {
                term.scrollTop = term.scrollHeight;
            }
            pendingReset = false;
        }

        function clearTerminal() { clearedAt = textLines.length; scheduleRenderText(false); }

        // ---------------------------------------------------------------------
        // Karte mit OpenStreetMap-Kacheln
        // ---------------------------------------------------------------------
        let mapData = null;
        let mapZoomLevel = 5;
        let mapCenter = { lat: 50.0, lon: 10.0 };
        let isMapDragging = false;
        let dragStart = { x: 0, y: 0 };
        let dragCenterStart = { lat: 0, lon: 0 };
        let selectedMarker = null;
        let mapFitted = false;

        const mapWrap = $("map-wrap"), mapCanvas = $("map-canvas"), mapCtx = mapCanvas.getContext("2d"), mapTiles = $("map-tiles");

        function resizeMapCanvas() {
            const rect = mapWrap.getBoundingClientRect();
            const w = Math.floor(rect.width), h = Math.floor(rect.height);
            if (w > 0 && h > 0 && (mapCanvas.width !== w || mapCanvas.height !== h)) { mapCanvas.width = w; mapCanvas.height = h; }
        }

        function latLonToWorld(lat, lon, zoom) {
            const n = Math.pow(2, zoom);
            const x = (lon + 180.0) / 360.0 * n * 256.0;
            const latRad = lat * Math.PI / 180.0;
            const y = (1.0 - Math.log(Math.tan(latRad) + 1.0 / Math.cos(latRad)) / Math.PI) / 2.0 * n * 256.0;
            return { x, y };
        }
        function worldToLatLon(x, y, zoom) {
            const n = Math.pow(2, zoom);
            const lon = (x / (n * 256.0)) * 360.0 - 180.0;
            const latRad = Math.atan(Math.sinh(Math.PI * (1.0 - 2.0 * (y / (n * 256.0)))));
            return { lat: latRad * 180.0 / Math.PI, lon };
        }
        function latLonToScreen(lat, lon) {
            const c = latLonToWorld(mapCenter.lat, mapCenter.lon, mapZoomLevel);
            const p = latLonToWorld(lat, lon, mapZoomLevel);
            return { x: mapCanvas.width / 2 + (p.x - c.x), y: mapCanvas.height / 2 + (p.y - c.y) };
        }

        function updateOsmTiles() {
            if (mapWrap.style.display === "none") return;
            const w = mapCanvas.width, h = mapCanvas.height;
            if (w <= 0 || h <= 0) return;
            const zoom = Math.floor(mapZoomLevel);
            const frac = mapZoomLevel - zoom;
            const centerWorld = latLonToWorld(mapCenter.lat, mapCenter.lon, zoom);
            const scale = Math.pow(2, frac);               // stufenloser Zoom: Kacheln der ganzen Stufe skalieren
            const halfW = w / 2 / scale, halfH = h / 2 / scale;
            const minWX = centerWorld.x - halfW, minWY = centerWorld.y - halfH;
            const n = Math.pow(2, zoom);
            const minTX = Math.floor(minWX / 256), maxTX = Math.floor((centerWorld.x + halfW) / 256);
            const minTY = Math.max(0, Math.floor(minWY / 256)), maxTY = Math.min(n - 1, Math.floor((centerWorld.y + halfH) / 256));
            const needed = new Set();
            for (let tx = minTX; tx <= maxTX; tx++) {
                for (let ty = minTY; ty <= maxTY; ty++) {
                    const ntx = ((tx % n) + n) % n;
                    const key = zoom + "_" + ntx + "_" + ty + "_" + tx;
                    needed.add(key);
                    let img = document.getElementById("tile-" + key);
                    if (!img) {
                        img = document.createElement("img");
                        img.id = "tile-" + key;
                        const sub = ["a", "b", "c"][(ntx + ty) % 3];
                        img.src = "https://" + sub + ".tile.openstreetmap.org/" + zoom + "/" + ntx + "/" + ty + ".png";
                        img.alt = "";
                        img.loading = "lazy";
                        img.style.transformOrigin = "0 0";
                        mapTiles.appendChild(img);
                    }
                    img.style.left = Math.round((tx * 256 - minWX) * scale) + "px";
                    img.style.top = Math.round((ty * 256 - minWY) * scale) + "px";
                    img.style.transform = "scale(" + scale + ")";
                }
            }
            Array.from(mapTiles.children).forEach(child => {
                if (!needed.has(child.id.replace("tile-", ""))) mapTiles.removeChild(child);
            });
        }

        const toneColors = { normal: "#00e676", info: "#00e5ff", highlight: "#ffb300", alert: "#ff3d00", dim: "#7890a8", weather: "#73b8ff" };

        /** Farbskala 0 (blau) … 0,5 (grün/gelb) … 1 (rot) wie MarkerBadge.scale der App */
        function levelColor(level) {
            const hue = 240 * (1 - Math.min(1, Math.max(0, level)));
            return "hsl(" + hue + ", 75%, 55%)";
        }

        function drawShape(name, x, y, heading, scale, color, selected) {
            const sh = shapes[name];
            if (!sh) return false;
            const zoomScale = mapZoomLevel >= 9 ? Math.min(2.2, 1 + 0.16 * (mapZoomLevel - 9)) : 1;
            const side = sh.size * (scale || 1) * zoomScale * (selected ? 1.3 : 1);
            mapCtx.save();
            mapCtx.translate(x, y);
            mapCtx.rotate(((heading || 0) * Math.PI) / 180);
            mapCtx.shadowColor = color;
            mapCtx.shadowBlur = selected ? 8 : 3;
            mapCtx.beginPath();
            sh.contours.forEach(c => {
                c.forEach((p, i) => {
                    const px = p[0] * side / 2, py = p[1] * side / 2;
                    if (i === 0) mapCtx.moveTo(px, py); else mapCtx.lineTo(px, py);
                });
                mapCtx.closePath();
            });
            mapCtx.fillStyle = color;
            mapCtx.fill("nonzero");
            mapCtx.shadowBlur = 0;
            mapCtx.lineJoin = "round";
            mapCtx.lineWidth = selected ? 1.6 : 0.9;
            mapCtx.strokeStyle = selected ? "#ffffff" : "rgba(0,0,0,0.7)";
            mapCtx.stroke();
            mapCtx.restore();
            return true;
        }

        function drawBadge(m, pos, color, selected) {
            const r = selected ? 12 : 9;
            if (m.heading !== undefined && m.heading !== null) {
                mapCtx.save();
                mapCtx.translate(pos.x, pos.y);
                mapCtx.rotate((m.heading * Math.PI) / 180);
                mapCtx.fillStyle = color;
                mapCtx.beginPath();
                mapCtx.moveTo(0, -r - 7); mapCtx.lineTo(4, -r - 1); mapCtx.lineTo(-4, -r - 1);
                mapCtx.closePath(); mapCtx.fill();
                mapCtx.restore();
            }
            mapCtx.beginPath();
            mapCtx.arc(pos.x, pos.y, r, 0, 2 * Math.PI);
            mapCtx.fillStyle = "rgba(11, 13, 15, 0.92)";
            mapCtx.fill();
            mapCtx.lineWidth = selected ? 2.5 : 1.5;
            mapCtx.strokeStyle = color;
            mapCtx.stroke();
            if (m.glyph) {
                mapCtx.fillStyle = color;
                mapCtx.font = (selected ? 13 : 10) + "px sans-serif";
                mapCtx.textAlign = "center"; mapCtx.textBaseline = "middle";
                mapCtx.fillText(m.glyph, pos.x, pos.y + 0.5);
            } else {
                mapCtx.beginPath();
                mapCtx.arc(pos.x, pos.y, 3, 0, 2 * Math.PI);
                mapCtx.fillStyle = color;
                mapCtx.fill();
            }
        }

        function drawValueBadge(m, pos, color, selected) {
            if (m.heading !== undefined && m.heading !== null) {
                mapCtx.save();
                mapCtx.translate(pos.x, pos.y);
                mapCtx.rotate((m.heading * Math.PI) / 180);
                mapCtx.fillStyle = color;
                mapCtx.beginPath();
                mapCtx.moveTo(0, -24); mapCtx.lineTo(5, -15); mapCtx.lineTo(-5, -15);
                mapCtx.closePath(); mapCtx.fill();
                mapCtx.restore();
            }
            mapCtx.font = "900 " + (selected ? 12 : 10) + "px " + getComputedStyle(document.body).fontFamily;
            const tw = mapCtx.measureText(m.value).width;
            const bw = tw + 10, bh = selected ? 18 : 15;
            const x = pos.x - bw / 2, y = pos.y - bh / 2;
            mapCtx.beginPath();
            if (mapCtx.roundRect) mapCtx.roundRect(x, y, bw, bh, bh / 2); else mapCtx.rect(x, y, bw, bh);
            mapCtx.fillStyle = color; mapCtx.fill();
            mapCtx.lineWidth = selected ? 2 : 1;
            mapCtx.strokeStyle = selected ? "#fff" : "rgba(0,0,0,0.4)";
            mapCtx.stroke();
            mapCtx.fillStyle = "rgba(0,0,0,0.85)";
            mapCtx.textAlign = "center"; mapCtx.textBaseline = "middle";
            mapCtx.fillText(m.value, pos.x, pos.y + 0.5);
        }

        function renderMap() {
            if (mapWrap.style.display === "none") return;
            resizeMapCanvas();
            updateOsmTiles();
            const w = mapCanvas.width, h = mapCanvas.height;
            mapCtx.clearRect(0, 0, w, h);
            if (!mapData) return;

            const hintEl = $("map-hint");
            if (mapData.hint) { hintEl.textContent = mapData.hint; hintEl.style.display = "block"; } else hintEl.style.display = "none";

            // Farbflächen (Temperatur) ganz unten
            (mapData.patches || []).forEach(p => {
                mapCtx.beginPath();
                p.corners.forEach((c, i) => { const s = latLonToScreen(c[0], c[1]); if (i === 0) mapCtx.moveTo(s.x, s.y); else mapCtx.lineTo(s.x, s.y); });
                mapCtx.closePath();
                mapCtx.globalAlpha = 0.35; mapCtx.fillStyle = levelColor(p.level); mapCtx.fill(); mapCtx.globalAlpha = 1;
            });
            // Isobaren
            (mapData.contours || []).forEach(c => {
                mapCtx.beginPath();
                c.points.forEach((q, i) => { const s = latLonToScreen(q[0], q[1]); if (i === 0) mapCtx.moveTo(s.x, s.y); else mapCtx.lineTo(s.x, s.y); });
                mapCtx.strokeStyle = "rgba(115, 184, 255, 0.75)"; mapCtx.lineWidth = 1; mapCtx.stroke();
                if (c.label && c.at) {
                    const s = latLonToScreen(c.at[0], c.at[1]);
                    mapCtx.font = "bold 9px " + getComputedStyle(document.body).fontFamily;
                    mapCtx.fillStyle = "#73b8ff"; mapCtx.textAlign = "center"; mapCtx.textBaseline = "middle";
                    mapCtx.fillText(c.label, s.x, s.y);
                }
            });
            // Linien
            (mapData.lines || []).forEach(line => {
                if (!line.points || line.points.length < 2) return;
                mapCtx.beginPath();
                line.points.forEach((q, i) => { const s = latLonToScreen(q[0], q[1]); if (i === 0) mapCtx.moveTo(s.x, s.y); else mapCtx.lineTo(s.x, s.y); });
                mapCtx.strokeStyle = toneColors[line.tone] || "#7890a8";
                mapCtx.lineWidth = line.tone === "dim" ? 1 : 1.5;
                mapCtx.setLineDash(line.tone === "dim" ? [4, 4] : []);
                mapCtx.stroke(); mapCtx.setLineDash([]);
            });
            // Wege der Fahrzeuge
            (mapData.markers || []).forEach(m => {
                if (!m.track || m.track.length < 2) return;
                mapCtx.beginPath();
                m.track.forEach((q, i) => { const s = latLonToScreen(q[0], q[1]); if (i === 0) mapCtx.moveTo(s.x, s.y); else mapCtx.lineTo(s.x, s.y); });
                mapCtx.strokeStyle = "rgba(0, 229, 255, 0.4)"; mapCtx.lineWidth = 2; mapCtx.stroke();
            });
            // Reichweitenkreise
            (mapData.markers || []).forEach(m => {
                if (!(m.radiusKm > 0)) return;
                const pos = latLonToScreen(m.lat, m.lon);
                const edge = latLonToScreen(m.lat, m.lon + (m.radiusKm / (111.32 * Math.cos(m.lat * Math.PI / 180))));
                const color = m.level !== undefined ? levelColor(m.level) : (toneColors[m.tone] || "#00e5ff");
                mapCtx.beginPath();
                mapCtx.arc(pos.x, pos.y, Math.abs(edge.x - pos.x), 0, 2 * Math.PI);
                mapCtx.globalAlpha = 0.1; mapCtx.fillStyle = color; mapCtx.fill(); mapCtx.globalAlpha = 1;
                mapCtx.strokeStyle = color; mapCtx.lineWidth = 1; mapCtx.stroke();
            });
            // Marker: Umriss von oben (Flugzeuge, Schiffe), Messwert-Kapsel oder Zeichen im Kreis
            (mapData.markers || []).forEach(m => {
                const pos = latLonToScreen(m.lat, m.lon);
                if (pos.x < -40 || pos.y < -40 || pos.x > w + 40 || pos.y > h + 40) return;
                const color = m.level !== undefined ? levelColor(m.level) : (toneColors[m.tone] || "#00e5ff");
                const sel = selectedMarker && selectedMarker.id === m.id;
                if (m.value) drawValueBadge(m, pos, color, sel);
                else if (!(m.shape && drawShape(m.shape, pos.x, pos.y, m.heading, m.scale, color, sel))) drawBadge(m, pos, color, sel);
                if (sel) {
                    mapCtx.beginPath(); mapCtx.arc(pos.x, pos.y, 16, 0, 2 * Math.PI);
                    mapCtx.strokeStyle = "#ffb300"; mapCtx.lineWidth = 2; mapCtx.stroke();
                }
                if (m.title && !m.value) {
                    mapCtx.font = "bold 10px " + getComputedStyle(document.body).fontFamily;
                    mapCtx.textAlign = "left"; mapCtx.textBaseline = "alphabetic";
                    mapCtx.fillStyle = "#e6f0fa"; mapCtx.shadowColor = "#000"; mapCtx.shadowBlur = 3;
                    mapCtx.fillText(m.title, pos.x + 13, pos.y + 3);
                    mapCtx.shadowBlur = 0;
                }
            });
            // Eigener Standort
            if (mapData.home) {
                const hp = latLonToScreen(mapData.home[0], mapData.home[1]);
                mapCtx.beginPath(); mapCtx.arc(hp.x, hp.y, 6, 0, 2 * Math.PI);
                mapCtx.fillStyle = "#ff3d00"; mapCtx.fill();
                mapCtx.strokeStyle = "#fff"; mapCtx.lineWidth = 2; mapCtx.stroke();
            }
        }

        mapWrap.addEventListener("pointerdown", (e) => {
            if (e.target.closest("button") || e.target.closest(".map-btns") || e.target.closest(".map-popup")) return;
            isMapDragging = true;
            dragStart = { x: e.clientX, y: e.clientY, moved: false };
            dragCenterStart = { lat: mapCenter.lat, lon: mapCenter.lon };
            mapWrap.classList.add("dragging");
            mapWrap.setPointerCapture(e.pointerId);
        });
        mapWrap.addEventListener("pointermove", (e) => {
            if (!isMapDragging) return;
            const dx = e.clientX - dragStart.x, dy = e.clientY - dragStart.y;
            if (Math.abs(dx) + Math.abs(dy) > 3) dragStart.moved = true;
            const sw = latLonToWorld(dragCenterStart.lat, dragCenterStart.lon, mapZoomLevel);
            mapCenter = worldToLatLon(sw.x - dx, sw.y - dy, mapZoomLevel);
            mapFitted = true;
            renderMap();
        });
        mapWrap.addEventListener("pointerup", (e) => {
            if (!isMapDragging) return;
            isMapDragging = false;
            mapWrap.classList.remove("dragging");
            if (!dragStart.moved) mapClick(e);
        });
        mapWrap.addEventListener("pointercancel", () => { isMapDragging = false; mapWrap.classList.remove("dragging"); });
        mapWrap.addEventListener("wheel", (e) => { e.preventDefault(); mapZoom(e.deltaY < 0 ? 0.3 : -0.3); }, { passive: false });

        function mapClick(e) {
            const rect = mapCanvas.getBoundingClientRect();
            const cx = e.clientX - rect.left, cy = e.clientY - rect.top;
            const pop = $("map-popup");
            let hit = null;
            if (mapData && mapData.markers) {
                for (let i = mapData.markers.length - 1; i >= 0; i--) {
                    const m = mapData.markers[i];
                    const pos = latLonToScreen(m.lat, m.lon);
                    if (Math.hypot(cx - pos.x, cy - pos.y) <= 16) { hit = m; break; }
                }
            }
            if (hit) {
                selectedMarker = hit;
                const esc = (t) => String(t).replace(/[&<>]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));
                let html = '<div class="pt">' + (hit.glyph ? esc(hit.glyph) + " " : "") + esc(hit.title) + "</div>";
                if (hit.sub) html += '<div class="ps">' + esc(hit.sub) + "</div>";
                if (hit.details && hit.details.length > 0) html += '<div class="pd">' + hit.details.map(d => "• " + esc(d)).join("<br>") + "</div>";
                pop.innerHTML = html;
                pop.style.display = "block";
            } else {
                selectedMarker = null;
                pop.style.display = "none";
            }
            renderMap();
        }

        function mapZoom(step) {
            mapZoomLevel = Math.max(2, Math.min(18, mapZoomLevel + step));
            mapFitted = true;
            renderMap();
        }

        function mapFit() {
            if (!mapData || !mapData.markers || mapData.markers.length === 0) {
                if (mapData && mapData.home) { mapCenter = { lat: mapData.home[0], lon: mapData.home[1] }; mapZoomLevel = 8; renderMap(); }
                return;
            }
            let minLat = 90, maxLat = -90, minLon = 180, maxLon = -180;
            mapData.markers.forEach(m => {
                minLat = Math.min(minLat, m.lat); maxLat = Math.max(maxLat, m.lat);
                minLon = Math.min(minLon, m.lon); maxLon = Math.max(maxLon, m.lon);
            });
            mapCenter = { lat: (minLat + maxLat) / 2, lon: (minLon + maxLon) / 2 };
            const maxSpan = Math.max(0.1, maxLat - minLat, maxLon - minLon);
            mapZoomLevel = maxSpan > 60 ? 3 : maxSpan > 30 ? 4 : maxSpan > 15 ? 5 : maxSpan > 6 ? 6 : maxSpan > 2 ? 8 : 10;
            renderMap();
        }

        function toggleMapStyle() {
            const wrap = $("map-wrap"), btn = $("btn-map-style");
            const dark = wrap.classList.toggle("dark");
            btn.textContent = dark ? "DUNKEL" : "HELL";
        }

        // ---------------------------------------------------------------------
        // WebSocket
        // ---------------------------------------------------------------------
        function connectWS() {
            const proto = window.location.protocol === "https:" ? "wss:" : "ws:";
            ws = new WebSocket(proto + "//" + window.location.host + "/ws");
            ws.binaryType = "arraybuffer";

            ws.onopen = () => {
                $("ws-dot").className = "status-dot connected";
                $("ws-status").textContent = "ONLINE";
                // Einstellungen dieser Seite der neuen Verbindung wieder mitteilen
                if (audioRunning) send({ cmd: "setAudioStream", enabled: true });
                if (currentView === "map") send({ cmd: "setMap", enabled: true });
            };

            ws.onclose = () => {
                $("ws-dot").className = "status-dot";
                $("ws-status").textContent = "OFFLINE";
                setTimeout(connectWS, 2000);
            };

            ws.onmessage = (event) => {
                if (typeof event.data === "string") {
                    try { handleJsonMessage(JSON.parse(event.data)); } catch (e) { console.error(e); }
                } else if (event.data instanceof ArrayBuffer) {
                    handleBinaryMessage(event.data);
                }
            };
        }

        function formatFrequency(hz) {
            if (!hz || hz <= 0) return { text: "---", unit: "MHz" };
            if (hz < 1e6) return { text: (hz / 1e3).toFixed(3).replace(".", ","), unit: "kHz" };
            return { text: (hz / 1e6).toFixed(6).replace(".", ","), unit: "MHz" };
        }

        function renderVfo() {
            const f = formatFrequency(state.dialHz);
            const el = $("freq-val");
            if (!el.querySelector("input")) el.textContent = f.text;
            $("freq-unit").textContent = f.unit;
            el.classList.toggle("fixed", !state.freqEditable);
            document.querySelector(".tuning-controls").style.display = state.freqEditable ? "" : "none";
            const src = $("source-tag");
            src.style.display = state.source ? "" : "none";
            src.textContent = state.source;
            const mg = $("mode-group");
            const sig = state.modes.join("|") + "@" + state.mode;
            if (mg.dataset.sig !== sig) {
                mg.dataset.sig = sig;
                mg.innerHTML = "";
                if (state.modes.length === 0) {
                    const l = document.createElement("span");
                    l.className = "mode-label";
                    l.textContent = state.mode;
                    mg.appendChild(l);
                } else {
                    state.modes.forEach(m => {
                        const b = document.createElement("button");
                        b.textContent = m;
                        b.className = m === state.mode ? "active" : "";
                        b.onclick = () => send({ cmd: "setMode", mode: m });
                        mg.appendChild(b);
                    });
                }
            }
        }

        // Auswahlmenüs des Moduls (Kanal, Band, Betriebsart, Sender): nur neu aufbauen, wenn sich Listen ändern; offenes Menü nicht stören
        function renderPresets(groups) {
            const bar = $("preset-bar");
            const sig = groups.map(g => g.key + ":" + g.options.map(o => o.id + "=" + o.label).join(",")).join("|");
            if (bar.dataset.sig !== sig) {
                bar.dataset.sig = sig;
                bar.innerHTML = "";
                groups.forEach(g => {
                    const item = document.createElement("div");
                    item.className = "preset-item";
                    const lbl = document.createElement("label");
                    lbl.textContent = g.label;
                    const sel = document.createElement("select");
                    sel.className = "sdr-select";
                    sel.dataset.key = g.key;
                    sel.title = g.label;
                    g.options.forEach(o => {
                        const opt = document.createElement("option");
                        opt.value = o.id; opt.textContent = o.label;
                        sel.appendChild(opt);
                    });
                    sel.onchange = () => { if (sel.value !== "") send({ cmd: "setPreset", key: g.key, id: sel.value }); };
                    item.appendChild(lbl); item.appendChild(sel);
                    bar.appendChild(item);
                });
            }
            groups.forEach(g => {
                const sel = bar.querySelector('select[data-key="' + g.key + '"]');
                if (sel && document.activeElement !== sel) sel.value = g.options.some(o => o.id === g.selected) ? g.selected : "";
            });
        }

        function editFrequency() {
            if (!state.freqEditable) return;
            const el = $("freq-val");
            if (el.querySelector("input")) return;
            const input = document.createElement("input");
            input.className = "freq-input";
            input.value = formatFrequency(state.dialHz).text;
            el.textContent = "";
            el.appendChild(input);
            input.focus(); input.select();
            let done = false;
            const finish = (commit) => {
                if (done) return; done = true;
                const raw = input.value.trim().toLowerCase();
                el.textContent = "";
                if (commit && raw) {
                    const n = parseFloat(raw.replace(",", "."));
                    if (isFinite(n) && n > 0) {
                        const hz = raw.endsWith("k") ? n * 1e3 : raw.endsWith("m") ? n * 1e6 : (n < 3000 ? n * 1e6 : n * 1e3);
                        send({ cmd: "setFrequency", hz: Math.round(hz) });
                    }
                }
                renderVfo();
            };
            input.onkeydown = (e) => { if (e.key === "Enter") finish(true); else if (e.key === "Escape") finish(false); };
            input.onblur = () => finish(true);
        }

        function handleJsonMessage(msg) {
            if (msg.type === "modules") {
                if (msg.shapes) shapes = msg.shapes;
                if (msg.modules) renderModuleBar(msg.modules);
            } else if (msg.type === "state") {
                if (msg.module && msg.module !== currentModule) {
                    currentModule = msg.module;
                    mapData = null; selectedMarker = null; mapFitted = false; $("map-popup").style.display = "none";
                    document.querySelectorAll(".module-btn").forEach(b => b.classList.remove("active"));
                    const activeBtn = $("mod-" + msg.module);
                    if (activeBtn) activeBtn.classList.add("active");
                    const modInfo = knownModules.find(m => m.id === msg.module);
                    const tabMap = $("tab-map");
                    if (modInfo && !modInfo.hasMap) { tabMap.title = "Dieses Modul hat keine Ortsdaten"; tabMap.style.opacity = "0.5"; }
                    else { tabMap.title = "Kartenansicht"; tabMap.style.opacity = "1"; }
                }
                state.dialHz = msg.dialHz || 0;
                state.mode = msg.mode || "";
                state.modes = msg.modes || [];
                state.freqEditable = !!msg.freqEditable;
                state.source = msg.source || "";
                renderVfo();
                if (msg.rig) $("rig-status").textContent = "Funkgerät: " + msg.rig;
                if (msg.sdr) {
                    sdrEnabled = !!msg.sdr.enabled;
                    isRFMode = !!msg.sdr.rfWaterfall;
                    const btnSdr = $("btn-sdr");
                    btnSdr.textContent = sdrEnabled ? "SDR: AN" : "SDR: AUS";
                    btnSdr.className = sdrEnabled ? "active" : "";
                    if (document.activeElement !== $("sel-sdr-src")) $("sel-sdr-src").value = msg.sdr.source || "hackrf";
                    const btnWf = $("btn-wf-mode");
                    btnWf.textContent = isRFMode ? "WASSERFALL: HF" : "WASSERFALL: NF";
                    btnWf.className = isRFMode ? "active" : "";
                    const badge = $("sdr-badge");
                    const txt = msg.sdr.status || (sdrEnabled ? "SDR Aktiv" : "Audio");
                    badge.textContent = txt;
                    badge.title = txt;
                    badge.className = "sdr-status-badge" + (txt.includes("Fehler") ? " error" : sdrEnabled ? " active" : "");
                }
            } else if (msg.type === "presets") {
                renderPresets(msg.groups || []);
            } else if (msg.type === "wf") {
                applyWfInfo(msg);
            } else if (msg.type === "text") {
                applyText(msg);
            } else if (msg.type === "map") {
                mapData = msg;
                if (!mapFitted && msg.markers && msg.markers.length) { mapFit(); mapFitted = true; }
                else if (!mapFitted && msg.home) { mapCenter = { lat: msg.home[0], lon: msg.home[1] }; mapZoomLevel = 6; mapFitted = true; }
                if (currentView === "map") renderMap();
            }
        }

        function handleBinaryMessage(buffer) {
            const v = new DataView(buffer);
            if (v.byteLength < 2) return;
            const tag = v.getUint8(0);
            if (tag === 0x01 && v.byteLength > 10) {
                // Wasserfallzeile: [0x01][Art][lo Float32 LE][hi Float32 LE][Farbindizes]
                onRow(v.getUint8(1), v.getFloat32(2, true), v.getFloat32(6, true), new Uint8Array(buffer, 10));
            } else if (tag === 0x03 && audioRunning && audioCtx && v.byteLength > 4) {
                // Audio: [0x03][Kanäle][Rate UInt16 LE][Int16 LE verschachtelt]
                playAudioChunk(v.getUint8(1), v.getUint16(2, true), new Int16Array(buffer, 4, Math.floor((v.byteLength - 4) / 2)));
            }
        }

        // ---------------------------------------------------------------------
        // Audio (Web Audio API): Rate und Kanäle liefert der Host (8 bis 48 kHz, mono oder stereo)
        // ---------------------------------------------------------------------
        function initAudio(rate) {
            const AC = window.AudioContext || window.webkitAudioContext;
            if (audioCtx && rate && rate !== audioRate) {
                // andere Abtastrate der Quelle: Kontext in dieser Rate neu, sonst rechnet der Browser jeden kleinen Block einzeln um (Knacken)
                try { audioCtx.close(); } catch (e) {}
                audioCtx = null; audioGain = null; nextAudioTime = 0;
            }
            if (!audioCtx) {
                try { audioCtx = rate ? new AC({ sampleRate: rate }) : new AC(); } catch (e) { audioCtx = new AC(); }
                audioRate = rate || 0;
                audioGain = audioCtx.createGain();
                audioGain.gain.value = parseFloat($("vol-slider").value);
                audioGain.connect(audioCtx.destination);
            }
            if (audioCtx.state === "suspended") audioCtx.resume();
        }

        function toggleAudio() {
            initAudio(48000);
            audioRunning = !audioRunning;
            const btn = $("btn-audio");
            btn.textContent = audioRunning ? "AUDIO: AN" : "AUDIO: AUS";
            btn.classList.toggle("active", audioRunning);
            if (!audioRunning) $("audio-info").textContent = "";
            nextAudioTime = 0;
            send({ cmd: "setAudioStream", enabled: audioRunning });
        }

        function setVolume(v) { if (audioGain) audioGain.gain.value = parseFloat(v); }

        let audioInfoAt = 0;
        function playAudioChunk(channels, rate, int16) {
            const frames = Math.floor(int16.length / channels);
            if (frames <= 0) return;
            if (rate !== audioRate) initAudio(rate);
            const buffer = audioCtx.createBuffer(channels, frames, rate);
            for (let c = 0; c < channels; c++) {
                const ch = buffer.getChannelData(c);
                for (let i = 0; i < frames; i++) ch[i] = int16[i * channels + c] / 32768.0;
            }
            const source = audioCtx.createBufferSource();
            source.buffer = buffer;
            source.connect(audioGain);
            const now = audioCtx.currentTime;
            // Reserve gegen Netzschwankungen; läuft die Wiedergabe zu weit vor, Block auslassen (Verzögerung begrenzen)
            if (nextAudioTime < now + 0.01) nextAudioTime = now + 0.15;
            if (nextAudioTime - now > 0.9) return;
            source.start(nextAudioTime);
            nextAudioTime += buffer.duration;
            if (now - audioInfoAt > 1) {
                audioInfoAt = now;
                $("audio-info").textContent = (rate / 1000).toFixed(rate % 1000 ? 1 : 0).replace(".", ",") + " kHz " + (channels === 2 ? "Stereo" : "Mono");
            }
        }

        // ---------------------------------------------------------------------
        // Befehle
        // ---------------------------------------------------------------------
        function selectModule(id) { send({ cmd: "selectModule", module: id }); }
        function tuneOffset(hz) { send({ cmd: "tuneOffset", offsetHz: hz }); }
        function toggleSDR() { send({ cmd: "setSDREnabled", enabled: !sdrEnabled }); }
        function selectSDRSource(src) { send({ cmd: "setSDRSource", source: src }); }
        function toggleWaterfallMode() { send({ cmd: "setWaterfallMode", mode: isRFMode ? "af" : "rf" }); }

        resizeWF();
        connectWS();
    </script>
</body>
</html>
"""#
}
