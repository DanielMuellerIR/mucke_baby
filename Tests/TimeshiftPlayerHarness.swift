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
        let defaults = UserDefaults(suiteName: "TimeshiftPlayer-" + UUID().uuidString)!
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
        print("TimeshiftPlayer: Reserve, Hörmetadaten, Pause, Seek, Live, Alt-Ereignisse und Überlauf OK")
    }
}
