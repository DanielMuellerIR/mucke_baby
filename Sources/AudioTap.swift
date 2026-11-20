// AudioTap.swift — eigene Audioausgabe für Visualizer und optionale Musikerkennung.
//
// ANSATZ (Variante C, CoreAudio Process-Tap, macOS 14.2+): Wir tappen die TONAUSGABE des EIGENEN
// Prozesses ab — also denselben, bereits von CoreAudio getakteten Output wie der sichtbare
// VLCKit-Player. Der Tap liegt NACH der VLC-Lautstaerke; vor der Analyse rechnen wir den
// App-Regler darum wieder heraus, damit der Visualizer auch bei leiser Wiedergabe ausschlaegt.
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
import MuckeAudioTapPCM
import os

private let tapLog = Logger(subsystem: "de.danielmuller.macradio", category: "audiotap")

/// Liefert unveröffentlichte Audio-Messwerte an die Visualizer. Sie lesen
/// den aktuellen Stand pro Timeline-Frame, ohne SwiftUI mit Updates zu wecken.
// Gerätezustand gehört der Lifecycle-Queue. Analyse und UI teilen
// ausschließlich die über AudioTapAnalysis synchronisierten Messwerte.
final class AudioTap: ObservableObject, @unchecked Sendable {
    static let bandCount = 12
    static let waveCount = 220

    private let analysis = AudioTapAnalysis()
    private let analysisQueue = DispatchQueue(label: "de.danielmuller.macradio.audiotap.analysis",
                                              qos: .userInitiated)
    private let lifecycleKey = DispatchSpecificKey<Void>()
    private var analysisTimer: DispatchSourceTimer?
    private var input: AudioTapInput?

    init() { lifecycleQueue.setSpecific(key: lifecycleKey, value: ()) }
    deinit { stop() }

    var level: Float { analysis.level }
    var bands: [Float] { analysis.bands }
    var waveform: [Float] { analysis.waveform }
    var reactive: Bool { analysis.reactive }
    var isActive: Bool { analysis.isActive }
    var captureSampleRate: Double? { analysis.captureSampleRate }
    var recognitionCapture: RecognitionCapture { analysis.recognitionCapture }

    func setOutputVolume(_ volume: Float) { analysis.setOutputVolume(volume) }

    // CoreAudio-Process-Tap-Zustand (alle nur auf der Lifecycle-Queue angefasst).
    private var tapID = AudioObjectID(kAudioObjectUnknown)        // der Process-Tap
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)  // privates Aggregate-Device
    private var ioProcID: AudioDeviceIOProcID?
    private var tapChannels = 2          // Kanäle im Tap-Format (Stereo-Mixdown → 2)
    private var tapInterleaved = true    // Float interleaved (Standard) vs. planar
    private var tapSampleRate: Double = 0
    private var formatListener: AudioObjectPropertyListenerBlock?
    // Serielle Queue für Start/Stop, damit Auf-/Abbau nie überlappen.
    private let lifecycleQueue = DispatchQueue(label: "de.danielmuller.macradio.audiotap.lifecycle")

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
    func stop() {
        if DispatchQueue.getSpecific(key: lifecycleKey) != nil {
            teardownTap()
        } else {
            lifecycleQueue.sync { teardownTap() }
        }
    }

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
        guard readTapFormat() else {
            tapLog.error("AudioTap: nicht unterstütztes PCM-Format")
            teardownTap(); return
        }

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

        // Die Echtzeit-Funktion erhält nur den vorbereiteten PCM-Speicher.
        guard let input = AudioTapInput(channels: tapChannels, interleaved: tapInterleaved,
                                        sampleRate: tapSampleRate) else {
            tapLog.error("AudioTap: PCM-Speicher konnte nicht angelegt werden")
            teardownTap(); return
        }
        self.input = input
        analysis.setInput(input)

        var procID: AudioDeviceIOProcID?
        status = MuckeAudioPCMInstall(input.storage, aggregateID, &procID)
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

        let canRecognize = observeTapFormat()
        startAnalysis(input, canRecognize: canRecognize)
        notifyAvailability()
        tapLog.notice("AudioTap: CoreAudio-Process-Tap gestartet (\(self.tapChannels) Kanäle). Wartet auf Signal …")
    }

    private func teardownTap() {
        recognitionCapture.setLiveSource(nil)
        analysis.setAvailability(active: false, captureRate: nil)
        analysis.setInput(nil)
        if let listener = formatListener {
            var address = tapFormatAddress
            AudioObjectRemovePropertyListenerBlock(tapID, &address, lifecycleQueue, listener)
            formatListener = nil
        }

        var ioProcRemoved = true
        if let p = ioProcID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateID, p)
            ioProcRemoved = AudioDeviceDestroyIOProcID(aggregateID, p) == noErr
        }
        ioProcID = nil
        analysisTimer?.cancel()
        analysisTimer = nil
        // Eine bereits laufende Analyse abschließen, dann alte Blöcke verwerfen.
        analysisQueue.sync { analysis.reset() }

        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if !ioProcRemoved, let input {
            // Der Geräteabbau ist asynchron. Bei fehlgeschlagener Abmeldung kann
            // CoreAudio noch auf den rohen Callback-Kontext zugreifen.
            _ = Unmanaged.passRetained(input)
            tapLog.error("AudioTap: PCM-Kontext bleibt nach fehlgeschlagenem IOProc-Abbau erhalten")
        }
        input = nil
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        notifyAvailability()
    }

    private func notifyAvailability() {
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
    }

    private var tapFormatAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                  mScope: kAudioObjectPropertyScopeGlobal,
                                  mElement: kAudioObjectPropertyElementMain)
    }

    private func observeTapFormat() -> Bool {
        let watchedTap = tapID
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.tapID == watchedTap, self.isActive else { return }
            // Der neue Tap erhält seinen eigenen PCM-Puffer und sein eigenes Format.
            self.teardownTap(); self.startTap()
        }
        var address = tapFormatAddress
        guard AudioObjectAddPropertyListenerBlock(tapID, &address, lifecycleQueue, listener) == noErr else {
            return false
        }
        formatListener = listener
        return true
    }

    private func startAnalysis(_ input: AudioTapInput, canRecognize: Bool) {
        if canRecognize {
            recognitionCapture.setLiveSource(input.recognitionSource)
        }
        analysis.setAvailability(active: true, captureRate: canRecognize ? input.sampleRate : nil)

        let timer = DispatchSource.makeTimerSource(queue: analysisQueue)
        timer.setEventHandler { [analysis] in analysis.drain(input) }
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(2))
        analysisTimer = timer
        timer.activate()
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
        // CoreAudio schreibt eine +1-retainte CFStringRef roh in den Slot. Deshalb NICHT in
        // eine ARC-verwaltete `CFString`-Variable schreiben (der Compiler warnt zu Recht: `&` auf
        // einen Referenztyp umgeht ARC → undefiniert, und der Anfangswert leakt). Stattdessen in
        // ein zeiger-grosses, ARC-inertes `Unmanaged<CFString>?` schreiben und das +1 mit
        // takeRetainedValue() korrekt konsumieren.
        var cfUIDRef: Unmanaged<CFString>? = nil
        var usz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = AudioObjectGetPropertyData(dev, &uidAddr, 0, nil, &usz, &cfUIDRef)
        return st == noErr ? (cfUIDRef?.takeRetainedValue() as String?) : nil
    }

    /// Liest das Stream-Format des Taps (Kanäle, interleaved/planar).
    private func readTapFormat() -> Bool {
        var addr = tapFormatAddress
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd) == noErr,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              asbd.mBitsPerChannel == 32, (1...32).contains(asbd.mChannelsPerFrame),
              asbd.mSampleRate.isFinite, (8000...192000).contains(asbd.mSampleRate) else { return false }
        tapChannels = Int(asbd.mChannelsPerFrame)
        tapInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        tapSampleRate = asbd.mSampleRate
        return asbd.mBytesPerFrame == UInt32(MemoryLayout<Float>.size * (tapInterleaved ? tapChannels : 1))
    }
}

private final class AudioTapInput {
    let storage: UnsafeMutableRawPointer
    let sampleRate: Double

    init?(channels: Int, interleaved: Bool, sampleRate: Double) {
        guard let storage = MuckeAudioPCMCreate(UInt32(channels), interleaved) else { return nil }
        self.storage = storage
        self.sampleRate = sampleRate
    }

    deinit { MuckeAudioPCMFree(storage) }

    var recognitionSource: RecognitionCapture.LiveSource {
        .init(nextSequence: { MuckeAudioPCMNextSequence(self.storage) },
              lastDrop: { MuckeAudioPCMLastDrop(self.storage) })
    }
}

// Der Timer hält nur den Analysestand. AudioTap kann dadurch unabhängig von
// der Analyse freigegeben werden und beim Stop synchron auf die Queue warten.
private final class AudioTapAnalysis {
    private var lock = os_unfair_lock_s()
    private let waveCount = AudioTap.waveCount
    private var _level: Float = 0
    private var _bands = [Float](repeating: 0, count: AudioTap.bandCount)
    private var _wave = [Float](repeating: 0, count: AudioTap.waveCount)
    private var _silentRuns = 120
    private var _outputVolume: Float = 1
    private var input: AudioTapInput?
    private var _isActive = false
    private var _captureRate: Double?
    let recognitionCapture = RecognitionCapture()

    private var loggedSignal = false
    private var nextSequence: UInt64 = 1

    // FFT-Zustand (Accelerate). Fixe Fenstergröße; Samples werden hineingeschoben.
    private let fftSize = 1024
    private var fftSetup: FFTSetup?
    private var window = [Float]()
    private var sampleRing = [Float]()     // gleitendes Mono-Fenster
    private var ringFill = 0
    // Bei extrem kleiner Lautstaerke wuerde 1/volume Rauschen und Rundungsreste massiv
    // aufblasen. Bis 1 % wird exakt kompensiert; darunter bleibt der Visualizer sichtbar,
    // aber nicht mehr mathematisch vollstaendig rekonstruierbar. Bei 0 % gibt es im Tap
    // tatsaechlich nur Stille.
    private let minimumRecoverableOutputVolume: Float = 0.01

    init() { setupFFT() }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

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

    var isActive: Bool {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return _isActive
    }

    var captureSampleRate: Double? {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return _captureRate
    }

    func setAvailability(active: Bool, captureRate: Double?) {
        os_unfair_lock_lock(&lock)
        _isActive = active
        _captureRate = captureRate
        os_unfair_lock_unlock(&lock)
    }

    /// Erhält der Process-Tap gerade echtes Audio? Ohne Signal ruhen die Visualizer.
    var reactive: Bool {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        guard _isActive else { return false }
        return _silentRuns < 120        // ~1–2 s Stille → als „kein Signal" werten
    }

    // MARK: Steuerung — Tap läuft, solange ein Sender spielt

    /// Tatsächliche lineare Ausgabeamplitude nach der kubischen AUHAL-Reglerskala.
    /// Der Process-Tap sieht das Signal NACH diesem Regler;
    /// fuer die Visualizer-Analyse rechnen wir ihn wieder heraus, damit die optische Dynamik
    /// nicht kleiner wird, nur weil leise gehoert wird.
    func setOutputVolume(_ volume: Float) {
        let clamped = max(0, min(1, volume))
        os_unfair_lock_lock(&lock)
        _outputVolume = clamped
        if let input { MuckeAudioPCMSetVolume(input.storage, clamped) }
        os_unfair_lock_unlock(&lock)
    }

    func setInput(_ input: AudioTapInput?) {
        os_unfair_lock_lock(&lock)
        self.input = input
        if let input { MuckeAudioPCMSetVolume(input.storage, _outputVolume) }
        os_unfair_lock_unlock(&lock)
    }

    // MARK: Analyse-Queue

    func drain(_ input: AudioTapInput) {
        for _ in 0..<Int(MuckeAudioPCMSlots) {
            let block = MuckeAudioPCMPeek(input.storage)
            guard let samples = block.samples else { return }

            if block.sequence != nextSequence {
                resetSignal()
            }
            nextSequence = block.sequence &+ 1

            let mono = UnsafeMutableBufferPointer(start: samples, count: block.frames)
            recognitionCapture.append(UnsafeBufferPointer(mono), sampleRate: input.sampleRate, sequence: block.sequence)
            feedMono(mono, outputVolume: block.volume)
            MuckeAudioPCMConsume(input.storage)
        }
    }

    func reset() {
        nextSequence = 1
        loggedSignal = false
        resetSignal()
    }

    private func resetSignal() {
        sampleRing = [Float](repeating: 0, count: fftSize)
        ringFill = 0
        os_unfair_lock_lock(&lock)
        _level = 0
        _bands = [Float](repeating: 0, count: AudioTap.bandCount)
        _wave = [Float](repeating: 0, count: AudioTap.waveCount)
        _silentRuns = 120
        os_unfair_lock_unlock(&lock)
    }

    /// Mono-Float-PCM (−1…1) → Lautstaerke-normalisieren → RMS + FFT + Oszilloskop-Kurve
    /// → publizieren. Die Normalisierung betrifft NUR den Visualizer, nicht die Wiedergabe.
    private func feedMono(_ mono: UnsafeMutableBufferPointer<Float>, outputVolume: Float) {
        guard let samples = mono.baseAddress, !mono.isEmpty else { return }
        normalizeVolume(samples, frames: mono.count, outputVolume: outputVolume)

        var meanSq: Float = 0
        vDSP_measqv(samples, 1, &meanSq, vDSP_Length(mono.count))
        let rms = sqrtf(meanSq)
        // Pegel-Kurve: moderater Gain (Headroom gegen Dauer-Anschlag) PLUS sanfte Kompression
        // (^0.7) — hebt leise Passagen (z.B. leise Klassik) sichtbar an, ohne laute Stellen
        // ständig ins Clipping zu treiben. Die Ballistik (Attack/Release) macht die Nadel selbst.
        let lvl = min(1, powf(rms * 3.5, 0.7))

        pushSamples(UnsafeBufferPointer(mono))
        let newBands = computeBands()
        // Oszilloskop-Schnappschuss: gleitendes Fenster auf `waveCount` Punkte herunterrechnen.
        var wave = [Float](repeating: 0, count: waveCount)
        let stride = max(1, fftSize / waveCount)
        for i in 0..<waveCount { wave[i] = sampleRing[i * stride] }

        let hasSignal = rms > 0.00005   // Auch leise, hörbare Musik zählt als Signal.
        if hasSignal, !loggedSignal {
            loggedSignal = true
            tapLog.notice("AudioTap: echtes Signal — Visualizer reagieren.")
        }

        os_unfair_lock_lock(&lock)
        if hasSignal {
            _silentRuns = 0
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

    /// Rechnet die tatsächliche Ausgabeamplitude aus den getappten Samples heraus.
    /// Beispiel: 0.25x-Amplitude im Tap → die Analyse erhält wieder 1.0x.
    private func normalizeVolume(_ samples: UnsafeMutablePointer<Float>, frames: Int, outputVolume: Float) {
        guard outputVolume > 0.0001 else { return }
        var gain = 1 / max(outputVolume, minimumRecoverableOutputVolume)
        guard abs(gain - 1) > 0.001 else { return }

        vDSP_vsmul(samples, 1, &gain, samples, 1, vDSP_Length(frames))

        // Nach der Rueckrechnung auf den normalen Float-PCM-Bereich begrenzen. Das schuetzt
        // vor kurzzeitigen Spitzen, ohne reale Musikdynamik fuer den Visualizer zu verlieren.
        var lo: Float = -1
        var hi: Float = 1
        vDSP_vclip(samples, 1, &lo, &hi, samples, 1, vDSP_Length(frames))
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

    private func pushSamples(_ new: UnsafeBufferPointer<Float>) {
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
        var maxv: Float = 0
        for b in 0..<AudioTap.bandCount {
            let lo = binIndex(b, total: AudioTap.bandCount, half: half)
            let hi = max(lo + 1, binIndex(b + 1, total: AudioTap.bandCount, half: half))
            var acc: Float = 0
            for k in lo..<min(hi, half) { acc += mags[k] }
            let avg = acc / Float(max(1, hi - lo))
            // `mags` ist Magnitude-QUADRAT (vDSP_zvmags) → zurück auf lineare Magnitude. Sonst
            // sättigt jede reale (Full-Scale-)Lautstärke sofort und ALLE Bänder kleben bei 1
            // (= flache Vollwand, Bug). Milder Höhen-Tilt, weil der Bass viel mehr Energie trägt.
            let mag = sqrtf(max(0, avg))
            let tilt = 1.0 + Float(b) * 0.30
            let v = mag * tilt
            out[b] = v
            if v > maxv { maxv = v }
        }
        // Pro Frame auf den stärksten Wert normieren → der Equalizer zeigt IMMER die spektrale
        // FORM (die Kontur wandert mit der Musik), statt bei lauter Musik als volle Wand zu kleben.
        // Bei (Quasi-)Stille NICHT hochskalieren (sonst Rausch-Flimmern; `reactive` ruht ohnehin).
        guard maxv > 1e-5 else { return [Float](repeating: 0, count: AudioTap.bandCount) }
        for b in out.indices { out[b] = min(1, out[b] / maxv) }
        return out
    }

    private func binIndex(_ band: Int, total: Int, half: Int) -> Int {
        let frac = Double(band) / Double(total)
        let idx = (pow(2.0, frac * log2(Double(half))) - 1)
        return min(half - 1, max(0, Int(idx)))
    }
}

#if AUDIO_TAP_HARNESS
extension AudioTapAnalysis {
    func receiveMonoFixture(_ samples: [Float]) {
        os_unfair_lock_lock(&lock)
        let volume = _outputVolume
        os_unfair_lock_unlock(&lock)
        var copy = samples
        copy.withUnsafeMutableBufferPointer { feedMono($0, outputVolume: volume) }
    }
}

// Synthetische Eingabe für den Harness ohne CoreAudio-Gerät oder Berechtigungsdialog.
extension AudioTap {
    func simulateRunningTap(sampleRate: Double, channels: Int = 2, interleaved: Bool = true) {
        lifecycleQueue.sync {
            precondition(input == nil)
            guard let fixture = AudioTapInput(channels: channels, interleaved: interleaved, sampleRate: sampleRate) else {
                preconditionFailure("PCM-Speicher für den Harness fehlt")
            }
            input = fixture
            analysis.setInput(fixture)
            recognitionCapture.setLiveSource(fixture.recognitionSource)
            analysis.setAvailability(active: true, captureRate: sampleRate)
        }
    }

    func receiveMonoFixture(_ samples: [Float]) {
        analysisQueue.sync { analysis.receiveMonoFixture(samples) }
    }

    func receivePCMFixture(_ buffers: UnsafePointer<AudioBufferList>) {
        enqueuePCMFixture(buffers)
        drainPCMFixture()
    }

    @discardableResult
    func enqueuePCMFixture(_ buffers: UnsafePointer<AudioBufferList>) -> Bool {
        guard let input else { return false }
        return MuckeAudioPCMSubmit(input.storage, buffers)
    }

    func drainPCMFixture() {
        guard let input else { return }
        analysisQueue.sync { analysis.drain(input) }
    }
}
#endif
