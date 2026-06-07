// AudioTap.swift — Audio-Reaktivität für die Theme-Visualizer.
//
// ANSATZ (Variante C, CoreAudio Process-Tap, macOS 14.4+): Wir tappen die TONAUSGABE des EIGENEN
// Prozesses ab — also exakt das, was der sichtbare VLCKit-Player gerade auf die Boxen gibt.
// Vorteile gegenüber dem früheren zweiten libVLC-Player (Variante B):
//   • PERFEKT SYNCHRON — es ist dasselbe Audio, kein zweiter Stream mit eigenem Puffer/Versatz.
//   • DURCHGEHEND FLÜSSIG — CoreAudio liefert regelmäßige kleine Puffer (kein 10-Hz-Geruckel).
//   • Kein zweiter Decoder → kein mpg123-Init-Crash, kein Start-Versatz, weniger CPU.
// Mechanik: pid → Prozess-AudioObject → CATapDescription (Stereo-Mixdown, NICHT stummschaltend) →
// AudioHardwareCreateProcessTap → privates Aggregate-Device mit dem Tap → IO-Proc liefert Float-PCM.
// Daraus rechnen wir wie bisher Pegel (RMS) + Spektrum (vDSP-FFT) + Oszilloskop-Kurve.
//
// KEIN Regress: solange kein echtes Signal ankommt (Stille/pausiert), bleibt `reactive` false →
// die Visualizer ruhen. Self-Tap des eigenen Prozesses braucht keine Mikrofon-Berechtigung.

import Foundation
import Accelerate
import CoreAudio
import os

private let tapLog = Logger(subsystem: "de.danielmuller.macradio", category: "audiotap")

/// Liefert Live-Audiodaten (Pegel + Bänder) des laufenden Senders an die Visualizer.
/// `level`/`bands` werden vom Audio-Callback geschrieben und von der UI pro Frame gelesen —
/// bewusst KEIN `@Published` (Audiorate würde SwiftUI überfluten); die Visualizer zeichnen
/// ohnehin jeden Frame via `TimelineView` und lesen den jeweils aktuellen Stand.
final class AudioTap: ObservableObject {

    /// Anzahl der Frequenzbänder, die wir nach außen geben (z.B. für Equalizer/Bars).
    static let bandCount = 12

    // Geteilter Zustand zwischen Audio-Callback (Schreiber) und Main/UI (Leser).
    private var lock = os_unfair_lock_s()
    static let waveCount = 220             // Punkte des Oszilloskop-Schnappschusses
    private let waveCount = AudioTap.waveCount
    private var _level: Float = 0          // geglätteter RMS-Pegel 0…1
    private var _bands = [Float](repeating: 0, count: AudioTap.bandCount)
    private var _wave = [Float](repeating: 0, count: AudioTap.waveCount)   // Oszilloskop-Kurve −1…1
    private var _silentRuns = 0            // aufeinanderfolgende stille Callback-Aufrufe
    private var loggedSignal = false       // einmaliges Log, sobald echtes Audio ankommt

    private(set) var isActive = false      // läuft der Tap gerade?

    // CoreAudio-Process-Tap-Zustand (alle nur auf der Lifecycle-Queue angefasst).
    private var tapID = AudioObjectID(kAudioObjectUnknown)        // der Process-Tap
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)  // privates Aggregate-Device
    private var ioProcID: AudioDeviceIOProcID?
    private var tapChannels = 2          // Kanäle im Tap-Format (Stereo-Mixdown → 2)
    private var tapInterleaved = true    // Float interleaved (Standard) vs. planar
    // Serielle Queue für Start/Stop, damit Auf-/Abbau nie überlappen.
    private let lifecycleQueue = DispatchQueue(label: "de.danielmuller.macradio.audiotap.lifecycle")

    // FFT-Zustand (Accelerate). Fixe Fenstergröße; Samples werden hineingeschoben.
    private let fftSize = 1024
    private var fftSetup: FFTSetup?
    private var window = [Float]()
    private var sampleRing = [Float]()     // gleitendes Mono-Fenster
    private var ringFill = 0

    init() { setupFFT() }
    deinit { stop(); if let s = fftSetup { vDSP_destroy_fftsetup(s) } }

    // MARK: Öffentlicher Lesezugriff (Main/UI, pro Frame)

    var level: Float {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return _level
    }
    var bands: [Float] {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return _bands
    }
    /// Aktuelle Oszilloskop-Kurve (−1…1, `waveCount` Punkte) — echte Wellenform fürs Scope.
    var waveform: [Float] {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return _wave
    }

    /// Liefert der Analyse-Player GERADE echtes Audio? Nur dann sollen die Visualizer ihn als
    /// Quelle nutzen; sonst (kein Sender, Verbindungsaufbau, Fehler) zeitbasiert weiter.
    var reactive: Bool {
        guard isActive else { return false }
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return _silentRuns < 120        // ~1–2 s Stille → als „kein Signal" werten
    }

    /// Verstärkungsfaktor für die Visualizer: bei echtem Signal aus dem Pegel (leise→klein,
    /// laut→voll), sonst 1.0 (reine Zeit-Animation wie bisher).
    var gain: Float {
        guard reactive else { return 1.0 }
        return 0.18 + 0.82 * min(1, level)
    }

    // MARK: Steuerung — Tap läuft, solange ein Sender spielt

    /// Wird bei jedem Senderwechsel mit der aktuellen Stream-URL gerufen. Der Tap ist
    /// URL-AGNOSTISCH (er greift die Ausgabe ab, egal welcher Sender) → wir starten ihn einmal,
    /// sobald etwas spielt, und stoppen bei nil/„".
    func setStream(_ url: URL?) {
        let playing = !((url?.absoluteString ?? "").isEmpty)
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            if playing { self.startTap() } else { self.teardownTap() }
        }
    }

    /// Öffentliches Stoppen (z.B. aus `deinit`).
    func stop() { lifecycleQueue.sync { self.teardownTap() } }

    // MARK: CoreAudio Process-Tap

    private func startTap() {
        guard !isActive else { return }
        let pid = getpid()

        // 1) pid → Prozess-AudioObject
        let procObj = processObject(for: pid)
        guard procObj != AudioObjectID(kAudioObjectUnknown) else {
            tapLog.error("AudioTap: pid→ProcessObject fehlgeschlagen"); return
        }

        // 2) Tap-Beschreibung: Stereo-Mixdown NUR unseres Prozesses (nicht anderer Apps),
        //    NICHT stummschalten — der Hauptton läuft normal weiter.
        let desc = CATapDescription(stereoMixdownOfProcesses: [procObj])
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        desc.name = "MuckeBabyTap"

        var newTap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(desc, &newTap)
        guard status == noErr, newTap != AudioObjectID(kAudioObjectUnknown) else {
            tapLog.error("AudioTap: CreateProcessTap status \(status)"); return
        }
        tapID = newTap

        // 3) Tap-Format lesen (Float, Kanäle, interleaved?).
        readTapFormat()

        // 4) Privates Aggregate-Device mit dem Tap. Es braucht ein OUTPUT-Sub-Device als Taktgeber
        //    (Default-Output), sonst wird der Tap nicht „gezogen" und liefert Stille.
        let outUID = defaultOutputDeviceUID()
        let aggUID = UUID().uuidString
        var aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MuckeBabyAgg",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [ kAudioSubTapUIDKey: desc.uuid.uuidString,
                  kAudioSubTapDriftCompensationKey: true ]
            ],
        ]
        if let outUID {
            aggDesc[kAudioAggregateDeviceSubDeviceListKey] = [[ kAudioSubDeviceUIDKey: outUID ]]
            aggDesc[kAudioAggregateDeviceMainSubDeviceKey] = outUID
        }
        var newAgg = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &newAgg)
        guard status == noErr, newAgg != AudioObjectID(kAudioObjectUnknown) else {
            tapLog.error("AudioTap: CreateAggregateDevice status \(status)")
            teardownTap(); return
        }
        aggregateID = newAgg

        // 5) IO-Proc installieren — liefert das getappte Float-PCM.
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) {
            [weak self] _, inInputData, _, _, _ in
            self?.handleTapInput(inInputData)
        }
        guard status == noErr, let procID else {
            tapLog.error("AudioTap: CreateIOProc status \(status)")
            teardownTap(); return
        }
        ioProcID = procID
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            tapLog.error("AudioTap: DeviceStart status \(status)")
            teardownTap(); return
        }

        isActive = true
        loggedSignal = false
        os_unfair_lock_lock(&lock); _silentRuns = 0; os_unfair_lock_unlock(&lock)
        tapLog.notice("AudioTap: CoreAudio-Process-Tap gestartet (\(self.tapChannels) Kanäle). Wartet auf Signal …")
    }

    private func teardownTap() {
        isActive = false
        if let p = ioProcID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateID, p)
            AudioDeviceDestroyIOProcID(aggregateID, p)
        }
        ioProcID = nil
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// pid → AudioObjectID des Prozesses (für die Tap-Beschreibung).
    private func processObject(for pid: pid_t) -> AudioObjectID {
        var pidVar = pid
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            UInt32(MemoryLayout<pid_t>.size), &pidVar, &size, &obj)
        return status == noErr ? obj : AudioObjectID(kAudioObjectUnknown)
    }

    /// UID des aktuellen Default-Output-Geräts (für den Aggregate-Takt).
    private func defaultOutputDeviceUID() -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(kAudioObjectUnknown)
        var sz = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &dev) == noErr,
              dev != AudioObjectID(kAudioObjectUnknown) else { return nil }
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID: CFString = "" as CFString
        var usz = UInt32(MemoryLayout<CFString>.size)
        let st = AudioObjectGetPropertyData(dev, &uidAddr, 0, nil, &usz, &cfUID)
        return st == noErr ? (cfUID as String) : nil
    }

    /// Liest das Stream-Format des Taps (Kanäle, interleaved/planar).
    private func readTapFormat() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd) == noErr {
            tapChannels = max(1, Int(asbd.mChannelsPerFrame))
            tapInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        }
    }

    /// IO-Proc-Callback (Realtime-Audio-Thread — schlank halten!): Float-PCM → Mono → Analyse.
    private func handleTapInput(_ inInputData: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        guard let first = abl.first, let raw = first.mData else { return }
        let ch = tapChannels

        var mono: [Float]
        if tapInterleaved || abl.count == 1 {
            // Interleaved: ein Buffer mit ch verschränkten Kanälen → Mittelwert je Frame.
            let total = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let frames = total / max(1, ch)
            guard frames > 0 else { return }
            let ptr = raw.assumingMemoryBound(to: Float.self)
            mono = [Float](repeating: 0, count: frames)
            if ch == 1 {
                for i in 0..<frames { mono[i] = ptr[i] }
            } else {
                let inv = Float(1) / Float(ch)
                for i in 0..<frames {
                    var acc: Float = 0
                    for c in 0..<ch { acc += ptr[i * ch + c] }
                    mono[i] = acc * inv
                }
            }
        } else {
            // Planar: ein Buffer je Kanal → kanalweise mitteln.
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            guard frames > 0 else { return }
            mono = [Float](repeating: 0, count: frames)
            var used = 0
            for b in abl {
                guard let bd = b.mData else { continue }
                let p = bd.assumingMemoryBound(to: Float.self)
                let n = min(frames, Int(b.mDataByteSize) / MemoryLayout<Float>.size)
                for i in 0..<n { mono[i] += p[i] }
                used += 1
            }
            if used > 1 { let inv = Float(1) / Float(used); for i in 0..<frames { mono[i] *= inv } }
        }
        feedMono(mono)
    }

    // MARK: Audio-Analyse (läuft auf dem CoreAudio-IO-Thread — schlank halten!)

    /// Mono-Float-PCM (−1…1) → RMS + FFT + Oszilloskop-Kurve → publizieren.
    private func feedMono(_ mono: [Float]) {
        let frames = mono.count
        guard frames > 0 else { return }

        var meanSq: Float = 0
        vDSP_measqv(mono, 1, &meanSq, vDSP_Length(frames))
        let rms = sqrtf(meanSq)
        // Pegel-Kurve: moderater Gain (Headroom gegen Dauer-Anschlag) PLUS sanfte Kompression
        // (^0.7) — hebt leise Passagen (z.B. leise Klassik) sichtbar an, ohne laute Stellen
        // ständig ins Clipping zu treiben. Die Ballistik (Attack/Release) macht die Nadel selbst.
        let lvl = min(1, powf(rms * 3.5, 0.7))

        pushSamples(mono)
        let newBands = computeBands()
        // Oszilloskop-Schnappschuss: gleitendes Fenster auf `waveCount` Punkte herunterrechnen.
        var wave = [Float](repeating: 0, count: waveCount)
        let stride = max(1, fftSize / waveCount)
        for i in 0..<waveCount { wave[i] = sampleRing[i * stride] }

        os_unfair_lock_lock(&lock)
        if rms > 0.00005 {   // sehr niedrig: leise (aber hörbare) Musik gilt als Signal, keine Nulllinie
            _silentRuns = 0
            if !loggedSignal { loggedSignal = true; tapLog.notice("AudioTap: echtes Signal — Visualizer reagieren.") }
        } else {
            _silentRuns = min(_silentRuns + 1, 100_000)
        }
        // NUR leichte Entrauschung der Callback-Sprünge — die eigentliche VU-Ballistik
        // (Attack/Release + 60-fps-Interpolation) sitzt jetzt in der Nadel (SingleVUMeter),
        // damit sie butterweich und frame-raten-unabhängig läuft.
        _level = _level * 0.5 + lvl * 0.5
        if let nb = newBands { _bands = nb }
        _wave = wave
        os_unfair_lock_unlock(&lock)
    }

    // MARK: FFT

    private func setupFFT() {
        let log2n = vDSP_Length(log2(Double(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        sampleRing = [Float](repeating: 0, count: fftSize)
        ringFill = 0
    }

    private func pushSamples(_ new: [Float]) {
        let n = new.count
        if n >= fftSize {
            for i in 0..<fftSize { sampleRing[i] = new[n - fftSize + i] }
            ringFill = fftSize; return
        }
        if ringFill + n <= fftSize {
            for i in 0..<n { sampleRing[ringFill + i] = new[i] }
            ringFill += n
        } else {
            let shift = ringFill + n - fftSize
            for i in 0..<(fftSize - n) { sampleRing[i] = sampleRing[i + shift] }
            for i in 0..<n { sampleRing[fftSize - n + i] = new[i] }
            ringFill = fftSize
        }
    }

    /// Grobes Spektrum in `bandCount` log-verteilte Bänder (0…1). Nil, wenn Fenster noch leer.
    private func computeBands() -> [Float]? {
        guard let setup = fftSetup, ringFill >= fftSize else { return nil }
        let half = fftSize / 2
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(sampleRing, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                let log2n = vDSP_Length(log2(Double(fftSize)))
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }

        var out = [Float](repeating: 0, count: AudioTap.bandCount)
        for b in 0..<AudioTap.bandCount {
            let lo = binIndex(b, total: AudioTap.bandCount, half: half)
            let hi = max(lo + 1, binIndex(b + 1, total: AudioTap.bandCount, half: half))
            var acc: Float = 0
            for k in lo..<min(hi, half) { acc += mags[k] }
            let avg = acc / Float(max(1, hi - lo))
            // Frequenz-Tilt: höhere Bänder haben natürlich viel weniger Energie als der Bass →
            // progressiv stärker gewichten, damit Mitten/Höhen im Equalizer nicht „tot" sind.
            let coeff = Float(0.0008 + Double(b) * 0.0016)
            out[b] = min(1, logf(1 + avg * coeff))
        }
        return out
    }

    private func binIndex(_ band: Int, total: Int, half: Int) -> Int {
        let frac = Double(band) / Double(total)
        let idx = (pow(2.0, frac * log2(Double(half))) - 1)
        return min(half - 1, max(0, Int(idx)))
    }
}
