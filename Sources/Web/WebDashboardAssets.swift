// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Enthält das vollwertige RadioTheme Single-Page Web-Dashboard für entfernte Browser.
/// Wird direkt aus dem Speicher als UTF-8 ausgeliefert (ohne Datei-Abhängigkeiten).
public enum WebDashboardAssets {
    public static let html: String = """
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
        }

        .brand {
            display: flex;
            align-items: baseline;
            gap: 8px;
        }

        .brand-title {
            font-size: 16px;
            font-weight: 900;
            letter-spacing: 1.5px;
            color: var(--vfd-cyan);
            text-shadow: 0 0 10px rgba(0, 229, 255, 0.4);
        }

        .brand-sub {
            font-size: 9px;
            font-weight: 700;
            color: var(--vfd-amber);
            letter-spacing: 1px;
        }

        .header-controls {
            display: flex;
            align-items: center;
            gap: 8px;
        }

        /* Status & Radio Info Pill */
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
            width: 7px;
            height: 7px;
            border-radius: 50%;
            background-color: var(--led-red);
            box-shadow: 0 0 6px var(--led-red);
        }
        .status-dot.connected {
            background-color: var(--vfd-green);
            box-shadow: 0 0 6px var(--vfd-green);
        }

        /* Buttons */
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
        button:hover {
            background: #252e37;
            border-color: var(--vfd-cyan);
        }
        button.active {
            background: var(--vfd-cyan);
            color: var(--bg-deep);
            border-color: var(--vfd-cyan);
            box-shadow: 0 0 8px rgba(0, 229, 255, 0.4);
        }

        /* Module Bar */
        .module-bar {
            background: var(--bg-panel);
            border-bottom: 1px solid var(--border-subtle);
            padding: 6px 14px;
            display: flex;
            gap: 4px;
            overflow-x: auto;
            flex-shrink: 0;
            white-space: nowrap;
        }
        .module-bar::-webkit-scrollbar { height: 4px; }
        .module-bar::-webkit-scrollbar-thumb { background: var(--border-bright); border-radius: 2px; }

        .module-btn {
            font-size: 10px;
            padding: 4px 8px;
            border-radius: 3px;
        }

        /* VFO / Frequency Display */
        .vfo-strip {
            background: #0f1317;
            border-bottom: 1px solid var(--border-subtle);
            padding: 8px 14px;
            display: flex;
            align-items: center;
            justify-content: space-between;
            flex-shrink: 0;
        }

        .freq-display {
            display: flex;
            align-items: baseline;
            gap: 6px;
        }

        .freq-readout {
            font-size: 22px;
            font-weight: 900;
            color: var(--vfd-cyan);
            letter-spacing: 1px;
            text-shadow: 0 0 12px rgba(0, 229, 255, 0.5);
        }

        .freq-unit {
            font-size: 11px;
            font-weight: bold;
            color: var(--text-dim);
        }

        .tuning-controls {
            display: flex;
            align-items: center;
            gap: 6px;
        }

        /* Main Workspace: Split Waterfall & Decoder Output */
        main {
            display: flex;
            flex-direction: column;
            flex: 1;
            min-height: 0;
            position: relative;
        }

        /* Waterfall Panel */
        .waterfall-container {
            flex: 1;
            min-height: 120px;
            background: #000;
            position: relative;
            overflow: hidden;
            display: flex;
            flex-direction: column;
        }

        #waterfall-canvas {
            width: 100%;
            height: 100%;
            display: block;
            image-rendering: pixelated;
        }

        .waterfall-overlay {
            position: absolute;
            top: 6px;
            left: 8px;
            font-size: 9px;
            color: rgba(255, 255, 255, 0.6);
            pointer-events: none;
            text-shadow: 0 1px 2px #000;
        }

        /* Splitter Resizer */
        .splitter {
            height: 6px;
            background: var(--bg-surface);
            border-top: 1px solid var(--border-subtle);
            border-bottom: 1px solid var(--border-subtle);
            cursor: row-resize;
            flex-shrink: 0;
        }
        .splitter:hover {
            background: var(--vfd-cyan-dim);
        }

        /* Decoder Output Panel */
        .output-panel {
            flex: 1;
            min-height: 140px;
            background: var(--bg-panel);
            display: flex;
            flex-direction: column;
            overflow: hidden;
        }

        .output-header {
            background: #111519;
            border-bottom: 1px solid var(--border-subtle);
            padding: 4px 12px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            font-size: 10px;
            font-weight: bold;
            color: var(--text-dim);
        }

        #terminal {
            flex: 1;
            padding: 10px;
            background: #0d1013;
            color: var(--vfd-cyan);
            font-size: 12px;
            line-height: 1.4;
            overflow-y: auto;
            word-break: break-all;
            white-space: pre-wrap;
            -webkit-user-select: text;
            user-select: text;
        }

        /* Audio Control Pill */
        .audio-bar {
            display: flex;
            align-items: center;
            gap: 8px;
        }
        .vol-slider {
            width: 70px;
            height: 4px;
            accent-color: var(--vfd-cyan);
        }

        /* Footer */
        footer {
            background: #0f1215;
            border-top: 1px solid var(--border-subtle);
            padding: 4px 14px;
            font-size: 10px;
            color: var(--text-dim);
            display: flex;
            justify-content: space-between;
            align-items: center;
            flex-shrink: 0;
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
                <button id="btn-audio" onclick="toggleAudio()">AUDIO: AUS</button>
                <input id="vol-slider" class="vol-slider" type="range" min="0" max="1" step="0.05" value="0.8" oninput="setVolume(this.value)">
            </div>
        </div>
    </header>

    <div id="module-bar" class="module-bar">
        <!-- Dynamisch befüllt mit RTTY, NAVTEX, WEFAX, APRS, AIS etc. -->
    </div>

    <div class="vfo-strip">
        <div class="freq-display">
            <span id="freq-val" class="freq-readout">---.---</span>
            <span class="freq-unit">kHz</span>
            <span id="mode-val" style="color: var(--vfd-amber); font-weight: bold; font-size: 11px; margin-left: 8px;">USB</span>
        </div>
        <div class="tuning-controls">
            <button onclick="tuneOffset(-1000)">-1 kHz</button>
            <button onclick="tuneOffset(-100)">-100 Hz</button>
            <button onclick="tuneOffset(100)">+100 Hz</button>
            <button onclick="tuneOffset(1000)">+1 kHz</button>
        </div>
    </div>

    <main>
        <div class="waterfall-container">
            <canvas id="waterfall-canvas"></canvas>
            <div class="waterfall-overlay">AUDIO / HF WASSERFALL (30 FPS)</div>
        </div>
        <div class="splitter"></div>
        <div class="output-panel">
            <div class="output-header">
                <span id="terminal-title">DECODER-EMPFANGSTEXT</span>
                <button onclick="clearTerminal()">LEEREN</button>
            </div>
            <div id="terminal">Warten auf Verbindung zum Digidec Host-Server...</div>
        </div>
    </main>

    <footer>
        <span id="rig-status">Funkgerät: --</span>
        <span id="client-info">Digidec WebEngine v0.99 · RadioTheme</span>
    </footer>

    <script>
        let ws = null;
        let audioCtx = null;
        let audioGain = null;
        let audioRunning = false;
        let nextAudioTime = 0;
        let currentModule = "rtty";
        let activeDialHz = 0;

        const modules = [
            { id: "rtty", label: "RTTY" },
            { id: "navtex", label: "NAVTEX" },
            { id: "wefax", label: "WEFAX" },
            { id: "psk", label: "PSK" },
            { id: "cw", label: "CW" },
            { id: "sstv", label: "SSTV" },
            { id: "dsc", label: "DSC" },
            { id: "pager", label: "PAGER" },
            { id: "packet", label: "PACKET" },
            { id: "aprs", label: "APRS" },
            { id: "ais", label: "AIS" },
            { id: "acars", label: "ACARS" }
        ];

        // Canvas Setup
        const canvas = document.getElementById("waterfall-canvas");
        const ctx = canvas.getContext("2d");
        let tempCanvas = document.createElement("canvas");
        let tempCtx = tempCanvas.getContext("2d");

        function resizeCanvas() {
            const rect = canvas.getBoundingClientRect();
            if (canvas.width !== rect.width || canvas.height !== rect.height) {
                canvas.width = rect.width;
                canvas.height = rect.height;
                tempCanvas.width = rect.width;
                tempCanvas.height = rect.height;
            }
        }
        window.addEventListener("resize", resizeCanvas);
        resizeCanvas();

        // RadioTheme Color Lookup Table (256 RGBA)
        const lut = new Uint32Array(256);
        (function buildLUT() {
            const stops = [
                { p: 0.00, r: 11, g: 13, b: 15 },
                { p: 0.20, r: 13, g: 46, b: 102 },
                { p: 0.40, r: 0, g: 153, b: 217 },
                { p: 0.55, r: 0, g: 229, b: 255 },
                { p: 0.70, r: 0, g: 230, b: 118 },
                { p: 0.82, r: 255, g: 179, b: 0 },
                { p: 0.93, r: 255, g: 61, b: 0 },
                { p: 1.00, r: 255, g: 242, b: 242 }
            ];
            for (let i = 0; i < 256; i++) {
                const x = i / 255;
                let upper = stops.findIndex(s => s.p >= x);
                if (upper === -1) upper = stops.length - 1;
                const lower = Math.max(0, upper - 1);
                const s0 = stops[lower], s1 = stops[upper];
                const t = s1.p > s0.p ? (x - s0.p) / (s1.p - s0.p) : 0;
                const r = Math.round(s0.r + (s1.r - s0.r) * t);
                const g = Math.round(s0.g + (s1.g - s0.g) * t);
                const b = Math.round(s0.b + (s1.b - s0.b) * t);
                lut[i] = (255 << 24) | (b << 16) | (g << 8) | r;
            }
        })();

        // Module Buttons init
        const modBar = document.getElementById("module-bar");
        modules.forEach(m => {
            const b = document.createElement("button");
            b.className = "module-btn" + (m.id === currentModule ? " active" : "");
            b.id = "mod-" + m.id;
            b.innerText = m.label;
            b.onclick = () => selectModule(m.id);
            modBar.appendChild(b);
        });

        // WebSocket Connection
        function connectWS() {
            const proto = window.location.protocol === "https:" ? "wss:" : "ws:";
            const wsUrl = proto + "//" + window.location.host + "/ws";
            ws = new WebSocket(wsUrl);
            ws.binaryType = "arraybuffer";

            ws.onopen = () => {
                document.getElementById("ws-dot").className = "status-dot connected";
                document.getElementById("ws-status").innerText = "ONLINE";
                appendTerminal("[SYSTEM] Verbunden mit Digidec Host-Server.\n");
            };

            ws.onclose = () => {
                document.getElementById("ws-dot").className = "status-dot";
                document.getElementById("ws-status").innerText = "OFFLINE";
                setTimeout(connectWS, 2000);
            };

            ws.onmessage = (event) => {
                if (typeof event.data === "string") {
                    try {
                        const msg = JSON.parse(event.data);
                        handleJsonMessage(msg);
                    } catch (e) {
                        appendTerminal(event.data);
                    }
                } else if (event.data instanceof ArrayBuffer) {
                    handleBinaryMessage(event.data);
                }
            };
        }

        function handleJsonMessage(msg) {
            if (msg.type === "state") {
                if (msg.module) {
                    currentModule = msg.module;
                    document.querySelectorAll(".module-btn").forEach(b => b.classList.remove("active"));
                    const activeBtn = document.getElementById("mod-" + msg.module);
                    if (activeBtn) activeBtn.classList.add("active");
                }
                if (msg.dialHz !== undefined) {
                    activeDialHz = msg.dialHz;
                    document.getElementById("freq-val").innerText = (msg.dialHz / 1000).toFixed(1);
                }
                if (msg.mode) {
                    document.getElementById("mode-val").innerText = msg.mode;
                }
                if (msg.rig) {
                    document.getElementById("rig-status").innerText = "Funkgerät: " + msg.rig;
                }
            } else if (msg.type === "text") {
                appendTerminal(msg.text);
            }
        }

        function handleBinaryMessage(buffer) {
            const bytes = new Uint8Array(buffer);
            if (bytes.length === 0) return;
            const channelTag = bytes[0]; // 0x01 = Waterfall Bins, 0x02 = 16-Bit PCM Audio

            if (channelTag === 0x01) {
                // Waterfall FFT Bins (Uint8 Values 0..255)
                drawWaterfallRow(bytes.subarray(1));
            } else if (channelTag === 0x02 && audioRunning && audioCtx) {
                // 16-bit PCM Audio, Little Endian, 8 kHz
                playAudioChunk(bytes.subarray(1));
            }
        }

        function drawWaterfallRow(bins) {
            resizeCanvas();
            const w = canvas.width;
            const h = canvas.height;
            if (w <= 0 || h <= 0) return;

            // Scroll existing content down by 1 pixel
            tempCtx.drawImage(canvas, 0, 0);
            ctx.drawImage(tempCanvas, 0, 1);

            // Draw new row at y=0
            const imgData = ctx.createImageData(w, 1);
            const data32 = new Uint32Array(imgData.data.buffer);
            const numBins = bins.length;

            for (let x = 0; x < w; x++) {
                const binIdx = Math.floor((x / w) * numBins);
                const val = bins[binIdx];
                data32[x] = lut[val];
            }
            ctx.putImageData(imgData, 0, 0);
        }

        // Web Audio API Player
        function initAudio() {
            if (!audioCtx) {
                const AudioContext = window.AudioContext || window.webkitAudioContext;
                audioCtx = new AudioContext({ sampleRate: 8000 });
                audioGain = audioCtx.createGain();
                audioGain.gain.value = parseFloat(document.getElementById("vol-slider").value);
                audioGain.connect(audioCtx.destination);
            }
            if (audioCtx.state === "suspended") {
                audioCtx.resume();
            }
        }

        function toggleAudio() {
            initAudio();
            audioRunning = !audioRunning;
            const btn = document.getElementById("btn-audio");
            if (audioRunning) {
                btn.innerText = "AUDIO: AN";
                btn.classList.add("active");
                if (ws && ws.readyState === WebSocket.OPEN) {
                    ws.send(JSON.stringify({ cmd: "setAudioStream", enabled: true }));
                }
            } else {
                btn.innerText = "AUDIO: AUS";
                btn.classList.remove("active");
                if (ws && ws.readyState === WebSocket.OPEN) {
                    ws.send(JSON.stringify({ cmd: "setAudioStream", enabled: false }));
                }
            }
        }

        function setVolume(v) {
            if (audioGain) {
                audioGain.gain.value = parseFloat(v);
            }
        }

        function playAudioChunk(bytes) {
            const int16 = new Int16Array(bytes.buffer, bytes.byteOffset, bytes.length / 2);
            const float32 = new Float32Array(int16.length);
            for (let i = 0; i < int16.length; i++) {
                float32[i] = int16[i] / 32768.0;
            }

            const buffer = audioCtx.createBuffer(1, float32.length, 8000);
            buffer.copyToChannel(float32, 0);

            const source = audioCtx.createBufferSource();
            source.buffer = buffer;
            source.connect(audioGain);

            const now = audioCtx.currentTime;
            if (nextAudioTime < now) {
                nextAudioTime = now + 0.02; // Small buffer lead
            }
            source.start(nextAudioTime);
            nextAudioTime += buffer.duration;
        }

        function appendTerminal(text) {
            const term = document.getElementById("terminal");
            term.textContent += text;
            term.scrollTop = term.scrollHeight;
        }

        function clearTerminal() {
            document.getElementById("terminal").textContent = "";
        }

        function selectModule(id) {
            if (ws && ws.readyState === WebSocket.OPEN) {
                ws.send(JSON.stringify({ cmd: "selectModule", module: id }));
            }
        }

        function tuneOffset(hz) {
            if (ws && ws.readyState === WebSocket.OPEN) {
                ws.send(JSON.stringify({ cmd: "tuneOffset", offsetHz: hz }));
            }
        }

        // Start
        connectWS();
    </script>
</body>
</html>
"""
}
