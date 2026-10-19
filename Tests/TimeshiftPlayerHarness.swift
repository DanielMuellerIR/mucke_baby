@main struct TimeshiftPlayerHarness {
    static func check(_ value: Bool, _ message: String) { precondition(value, message) }
    @MainActor static func wait(_ condition: () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Transportzustand fehlt")
    }
    static func frame() -> Data { Data([0xff, 0xfb, 0x90, 0] + [UInt8](repeating: 0, count: 413)) }
    @MainActor static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TimeshiftPlayer-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "TimeshiftPlayer-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = RadioPlayer(preferences: defaults, timeshiftRoot: root)
        check(!player.timeshiftRequested && !player.recordingRequested, "Defaults nicht aus")
        player.setTimeshiftRequested(true)
        let station = Station(name: "Fixture", url: "https://fixture.invalid/test")
        player.play(station)
        await wait { player.currentStreamURL != nil }
        let direct = VLCMediaPlayer.latest!, icy = ICYMetadataReader.latest!
        icy.format?("audio/mpeg", Date())
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        icy.boundary?("First - A", firstDate); icy.onTitle?("First - A", firstDate)
        for _ in 0..<100 { icy.audioAt?(frame(), Date(), 1) }
        try? await Task.sleep(for: .milliseconds(150))
        check(VLCMediaPlayer.latest === direct, "Start ohne drei Sekunden Reserve")
        for _ in 0..<100 { icy.audioAt?(frame(), Date(), 2) }
        await wait { VLCMediaPlayer.latest !== direct }
        let local = VLCMediaPlayer.latest!
        local.timeEvent(); await wait { player.isPlaying }
        let recognitionGeneration = player.recognitionContext?.generation
        check(player.timeshiftTransport.timeline.oldest >= 1, "Kalter Netzwerkanfang ist als Hörziel verfügbar")
        check(player.timeshiftTransport.delay >= 3 && player.nowPlayingTitle == "First - A", "Startreserve oder Titel falsch")
        icy.boundary?("Second - B", firstDate.addingTimeInterval(5))
        icy.onTitle?("Second - B", firstDate.addingTimeInterval(5))
        for _ in 0..<200 { icy.audioAt?(frame(), Date(), 3) }
        try? await Task.sleep(for: .milliseconds(150))
        check(player.nowPlayingTitle == "First - A", "Vorauslaufender Empfang ersetzt gehörten Titel")
        local.time.intValue = 6000
        local.timeEvent(); await wait { player.nowPlayingTitle == "Second - B" }
        player.pause(); check(player.isPaused && !player.isPlaying && player.hasPlaybackIntent, "Pause verliert Absicht")
        local.time.intValue = 9000
        try? await Task.sleep(for: .milliseconds(150))
        check(player.timeshiftTransport.position < 9, "Pause folgt Decoderzeit")
        let starts = icy.startCount
        player.seekTimeshift(to: 4)
        let sought = VLCMediaPlayer.latest!
        check(sought !== local && player.isPaused && sought.state == .stopped, "Seek in Pause startet Audio")
        check(player.timeshiftTransport.position <= 4.00001 && player.timeshiftTransport.position >= 4 - 1152.0 / 44100, "Seek verlässt gewählten MP3-Frame")
        player.resume(); sought.timeEvent(); await wait { player.isPlaying }
        check(player.recognitionContext?.generation != recognitionGeneration, "Seek behält alte Erkennung bei gleichem Titel")
        direct.state = .error; direct.stateEvent(); local.timeEvent()
        try? await Task.sleep(for: .milliseconds(150))
        check(player.isPlaying && icy.startCount == starts, "Alte Playerereignisse oder Seek starten Empfang neu")
        player.returnToLive(); let live = VLCMediaPlayer.latest!
        live.timeEvent(); await wait { player.isPlaying }
        check(player.timeshiftTransport.phase == .live && icy.startCount == starts, "Live startet ICY neu")
        player.pause()
        for _ in 0..<15_000 { icy.audioAt?(frame(), Date(), 4) }
        await wait { player.timeshiftTransport.phase == .expired }
        let expiredPlayer = VLCMediaPlayer.latest!
        try? await Task.sleep(for: .milliseconds(150))
        check(!player.isPlaying && VLCMediaPlayer.latest === expiredPlayer, "Pufferlimit startet heimlich Live")
        player.returnToLive(); check(VLCMediaPlayer.latest !== expiredPlayer, "Bewusste Live-Rückkehr fehlt")
        player.stop()
        check(!player.hasPlaybackIntent && player.timeshiftTransport.timeline.titles.isEmpty, "Stop behält Transport")
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        check(dirs.filter { UUID(uuidString: $0) != nil }.isEmpty, "Stop behält Leserdateien")
        var timerNow = 0.0
        let timed = RadioPlayer(preferences: defaults, metadataReconnect: PlaybackReconnect(delays: [0.01]),
            sleepTimer: SleepTimerController(now: { timerNow }), timeshiftRoot: root)
        timed.setTimeshiftRequested(true); timed.play(station)
        await wait { timed.currentStreamURL != nil }
        let timedICY = ICYMetadataReader.latest!
        func feed() {
            timedICY.format?("audio/mpeg", Date())
            for _ in 0..<250 { timedICY.audioAt?(frame(), Date(), 1) }
        }
        feed()
        await wait { VLCMediaPlayer.latest!.media != nil && timed.timeshiftTransport.timeline.canStart }
        try? await Task.sleep(for: .milliseconds(150))
        VLCMediaPlayer.latest!.timeEvent(); await wait { timed.isPlaying }
        timed.pause(); let pausedPlayer = VLCMediaPlayer.latest!, connections = timedICY.startCount
        timed.setRecordingRequested(true)
        timed.setRecordingRequested(false)
        check(timed.isPaused && VLCMediaPlayer.latest === pausedPlayer && timedICY.startCount == connections,
              "Aufnahmewechsel ersetzt pausierten MP3-Leser")
        var audio = AudioConfiguration(); audio.equalizerEnabled = true; audio.bands[3] = -12
        timed.configureAudio(audio)
        check(timed.isPaused && pausedPlayer.equalizer?.bands[3].amplification == -12, "EQ verliert Pause")
        timed.prepareForSleep()
        check(!timed.isPlaying && timed.currentStreamURL == nil, "Schlaf lässt Empfang/Leser offen")
        timed.resumeAfterWake()
        check(timed.hasPlaybackIntent && !timed.isPlaying && timed.timeshiftTransport.phase == .expired
              && VLCMediaPlayer.latest === pausedPlayer, "Aufwachen startet pausiertes Audio")
        timed.returnToLive()
        await wait { timed.currentStreamURL != nil }
        feed()
        await wait { timed.timeshiftTransport.timeline.canStart }
        VLCMediaPlayer.latest!.timeEvent(); await wait { timed.isPlaying }
        timed.pause()
        let reconnectedFrom = timedICY.startCount
        let ended = timedICY.completion!
        ended(Date())
        await wait { timedICY.startCount > reconnectedFrom }
        check(timed.timeshiftTransport.phase == .expired && !timed.isPlaying, "Metadaten-Reconnect startet Audio trotz Pause")
        feed()
        await wait { timed.timeshiftTransport.timeline.canStart }
        ended(Date())
        try? await Task.sleep(for: .milliseconds(150))
        check(timed.timeshiftTransport.timeline.canStart && !timed.isPlaying, "Alter Empfang beendet neuen Puffer")
        timed.returnToLive(); VLCMediaPlayer.latest!.timeEvent(); await wait { timed.isPlaying }
        check(VLCMediaPlayer.latest!.equalizer?.bands[3].amplification == -12, "Live verliert EQ")
        timed.pause()
        check(timed.sleepTimer.start(duration: 60), "Timer in Pause startet nicht")
        timerNow = 61; timed.sleepTimer.refresh()
        check(!timed.hasPlaybackIntent && timed.currentStreamURL == nil, "Timer beendet pausierten Empfang nicht")
        timed.resumeAfterWake()
        check(!timed.hasPlaybackIntent, "Timer-Stop wird beim Aufwachen aufgehoben")
        timed.play(Station(name: "HLS", url: "https://fixture.invalid/live.m3u8"))
        await wait { timed.currentStreamURL?.pathExtension == "m3u8" }
        let noICY = timedICY.startCount
        timed.setRecordingRequested(true)
        try? await Task.sleep(for: .milliseconds(150))
        check(timedICY.startCount == noICY && timed.metadataStatus != nil, "HLS öffnet ICY/Retry")
        timed.stop()
        let aacPlayer = RadioPlayer(preferences: defaults, timeshiftRoot: root)
        aacPlayer.setTimeshiftRequested(true)
        aacPlayer.play(Station(name: "AAC", url: "https://fixture.invalid/aac"))
        await wait { aacPlayer.currentStreamURL != nil }
        let aacDirect = VLCMediaPlayer.latest!, aacICY = ICYMetadataReader.latest!
        aacDirect.timeEvent(); await wait { aacPlayer.isPlaying }
        aacICY.format?("audio/aac", Date())
        let adts = Data([0xff, 0xf1, 0x4c, 0x80, 0x0c, 0xff, 0xfc] + [UInt8](repeating: 0, count: 96))
        for _ in 0..<300 { aacICY.audioAt?(adts, Date(), 1) }
        await wait { aacPlayer.timeshiftTransport.timeline.canStart && VLCMediaPlayer.latest !== aacDirect }
        let aacLocal = VLCMediaPlayer.latest!
        aacLocal.timeEvent(); await wait { aacPlayer.canPause }
        aacLocal.media?.tracksInformation = [["rate": 96000]]
        aacLocal.time.intValue = 1000; aacLocal.timeEvent()
        await wait { aacPlayer.timeshiftTransport.phase == .expired }
        check(!aacPlayer.isPlaying && aacPlayer.hasPlaybackIntent, "Geänderte AAC-Ausgaberate bleibt ungeprüft aktiv")
        aacPlayer.stop()
        print("TimeshiftPlayer: Reserve, Hörmetadaten, Pause, Seek, Live, Alt-Ereignisse und Überlauf OK")
    }
}
