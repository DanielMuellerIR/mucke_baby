import Foundation

@main
@MainActor
struct SleepTimerHarness {
    static func main() {
        func check(_ value: @autoclosure () -> Bool, _ reason: String) { precondition(value(), reason) }
        var schedule = SleepTimerSchedule()
        check(schedule.start(duration: 60, at: 100), "Gültige Frist abgewiesen")
        let original = schedule
        for invalid in [Double.nan, .infinity, 0, -1, 86401] {
            check(!schedule.start(duration: invalid, at: 100) && schedule == original, "Ungültige Dauer verändert Frist")
        }
        check(schedule.remaining(at: 150) == 10 && schedule.fadeFactor(at: 150) == 1, "Ausblenden beginnt zu früh")
        check(schedule.fadeFactor(at: 155) == 0.5, "Amplitude nicht stetig ausgeblendet")
        check(schedule.extend(by: 900, at: 155) && schedule.fadeFactor(at: 155) == 1, "Verlängern im Fade setzt Pegel nicht zurück")
        check(schedule.remaining(at: 155) == 905, "Verlängern ersetzt statt addiert Frist")
        check(schedule.remaining(at: 2000) == 0 && schedule.fadeFactor(at: 2000) == 0, "Übersprungener Ablauf nicht erkannt")
        check(!schedule.extend(by: 60, at: 2000), "Abgelaufener Timer wird verlängert")
        schedule.cancel();check(schedule.remaining(at: 2000) == nil && schedule.fadeFactor(at: 2000) == 1, "Abbruch bleibt stumm")

        var monotonicTime = 0.0, expirations = 0, desiredPlayback = true
        let timer = SleepTimerController(now: { monotonicTime })
        timer.onExpire = { expirations += 1; desiredPlayback = false }
        check(timer.start(duration: 20), "Injizierter Timer startet nicht")
        monotonicTime = 15;timer.refresh();check(timer.fadeFactor == 0.5, "Controller-Fade falsch")
        monotonicTime = 5;timer.refresh();check(timer.fadeFactor == 0.5, "Rückwärtszeit verlängert Frist")
        monotonicTime = 21;timer.refresh();timer.refresh()
        check(expirations == 1 && !desiredPlayback && timer.remaining == nil && timer.fadeFactor == 1, "Ablauf muss genau einmal stoppen und zurücksetzen")
        timer.extend(minutes: 15);check(timer.remaining == nil && expirations == 1, "Verlängern startet abgelaufene Wiedergabe")
        desiredPlayback = true;check(timer.start(duration: 60), "Neuer bewusster Timer blockiert")
        monotonicTime = 51;timer.refresh();timer.cancel();monotonicTime = 200;timer.refresh()
        check(expirations == 1 && desiredPlayback && timer.fadeFactor == 1 && timer.remaining == nil, "Abbruch feuert verspätet")
        check(timer.start(duration: 10), "Wiederholter Start fehlgeschlagen")
        monotonicTime = 202;check(timer.start(duration: 60), "Neue Frist ersetzt alte nicht")
        monotonicTime = 211;timer.refresh();check(expirations == 1, "Ersetzte Frist feuert")
        timer.cancel()
        print("Einschlaftimer: Fristen, Fade, Verlängern, Abbruch, Zeitrücksprung und übersprungene Zeit OK")
    }
}
