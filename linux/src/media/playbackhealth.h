#pragma once
#include <QtGlobal>
namespace Mucke::MediaPrivate {
class PlaybackHealth {
public:
    struct Tick { bool stalled = false, renewBudget = false; };
    void begin(qint64 now) { monitoring = true; lastProgress = now; stableSince = -1; renewed = false; reportedStall = false; }
    void cancel() { monitoring = false; }
    void progress(qint64 now) {
        if (!monitoring) return;
        if (stableSince < 0 || now - lastProgress > 3000) { stableSince = now; renewed = false; }
        lastProgress = now; reportedStall = false;
    }
    Tick tick(qint64 now) {
        if (!monitoring) return {};
        const qint64 gap = now - lastProgress;
        if (gap > 3000) { stableSince = -1; renewed = false; }
        if (gap >= 15000 && !reportedStall) { reportedStall = true; return {true, false}; }
        if (stableSince >= 0 && now - stableSince >= 60000 && !renewed) { renewed = true; return {false, true}; }
        return {};
    }
private:
    qint64 lastProgress = 0, stableSince = -1;
    bool monitoring = false, renewed = false, reportedStall = false;
};
}
