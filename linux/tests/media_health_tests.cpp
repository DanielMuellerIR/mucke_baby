#include "../src/media/playbackhealth.h"
#include <iostream>
#include <cstdlib>
using Mucke::MediaPrivate::PlaybackHealth;
static void check(bool value, const char *why) { if (!value) { std::cerr << why << '\n'; std::exit(1); } }
int main() {
    PlaybackHealth health; health.begin(0);
    check(!health.tick(14999).stalled && health.tick(15000).stalled && !health.tick(16000).stalled, "Startup stall is reported once at15s");
    health.begin(20000); health.progress(21000);
    for (qint64 now = 22000; now < 81000; now += 1000) { health.progress(now); check(!health.tick(now).renewBudget, "Flapping/short playback cannot renew retry budget"); }
    health.progress(81000); check(health.tick(81000).renewBudget && !health.tick(82000).renewBudget, "Budget renews once after60s actual progress");
    health.cancel(); check(!health.tick(500000).stalled, "Paused/stopped output does not retry");
    health.begin(600000); health.progress(601000); health.tick(605000); health.progress(606000);
    for (qint64 now = 607000; now < 666000; now += 1000) { health.progress(now); check(!health.tick(now).renewBudget, "Progress interruption restarts stability interval"); }
    health.progress(666000); check(health.tick(666000).renewBudget, "Fresh uninterrupted60s restores budget");
    std::cout << "media health:15s stall,60s stable renewal, flap/pause/stop guards passed\n";
}
