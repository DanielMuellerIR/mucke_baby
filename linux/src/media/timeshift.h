#pragma once
#include "../types.h"
#include <QByteArray>
#include <QStringList>
#include <memory>
#include <sys/types.h>
struct libvlc_instance_t;
struct libvlc_media_t;
namespace Mucke::MediaPrivate {
enum class BufferPhase { Off, Warming, Ready, Unsupported, LowDisk, InvalidAudio, FormatChanged, ReaderOverrun, Closed, IOError };
struct TimeshiftLimits {
    double seconds = 300;
    qint64 bytes = 32 * 1024 * 1024;
    int segments = 256;
    double segmentSeconds = 2;
    qint64 segmentBytes = 64 * 1024;
    qint64 minimumFreeBytes = 10LL * 1024 * 1024 * 1024;
};
struct TimeshiftAnchor { double position = 0; Track track; };
struct TimeshiftView {
    BufferPhase phase = BufferPhase::Off;
    QString reason;
    double oldest = 0, live = 0;
    qint64 bytes = 0;
    int segments = 0;
    QVector<TimeshiftAnchor> titles;
};
struct DecoderProfile {
    QString codec;
    int decodedSampleRate = 0, clockCorrectionFrames = 0;
    bool verified = false;
};
// Die Freigabe gilt für die vermessene libVLC-Version. Für AAC muss die
// tatsächliche Decoderfrequenz zusätzlich zum ADTS-Kernformat passen.
DecoderProfile verifiedTimeshiftProfile(QString codec, int decodedSampleRate);
// Nur die encodierte ADTS-Kernrate; 0 bei ungültigem/unvollständigem Header.
// Diese Funktion ersetzt keine Prüfung der tatsächlichen Decoderfrequenz.
int encodedAACSampleRate(const QByteArray &prefix);
struct TimeshiftState;
class TimeshiftReader {
public:
    ~TimeshiftReader();
    TimeshiftReader(const TimeshiftReader &) = delete;
    TimeshiftReader &operator=(const TimeshiftReader &) = delete;
    ssize_t read(unsigned char *output, size_t count);
    void cancel();
    double inputStart() const;
    double outputStart() const;
    QStringList mediaOptions() const;
    libvlc_media_t *createMedia(libvlc_instance_t *instance);
private:
    friend class TimeshiftBuffer;
    friend struct TimeshiftState;
    struct Cursor;
    TimeshiftReader(std::shared_ptr<TimeshiftState>, std::shared_ptr<Cursor>);
    std::shared_ptr<TimeshiftState> state_;
    std::shared_ptr<Cursor> cursor_;
};
class TimeshiftBuffer {
public:
    explicit TimeshiftBuffer(QString cacheRoot, TimeshiftLimits limits = {});
    ~TimeshiftBuffer();
    TimeshiftBuffer(const TimeshiftBuffer &) = delete;
    TimeshiftBuffer &operator=(const TimeshiftBuffer &) = delete;
    // MP3 mit DecoderProfile{"mp3"} wird erst am ersten Audioheader freigegeben.
    bool begin(QString contentType, QString sessionID, DecoderProfile profile);
    bool append(QByteArray data, QDateTime receivedAt);
    void noteTitle(Track track);
    bool checkDisk();
    TimeshiftView view() const;
    Track trackAt(double position) const;
    QDateTime receivedAt(double position) const;
    std::shared_ptr<TimeshiftReader> readerAt(double position);
    std::shared_ptr<TimeshiftReader> readerLive();
    void endReception();
    void close();
private:
    std::shared_ptr<TimeshiftState> state_;
};
}
