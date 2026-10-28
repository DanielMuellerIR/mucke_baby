#pragma once
#include <QDateTime>
#include <QMetaType>
#include <QJsonObject>
#include <QString>
#include <QStringList>
#include <QVector>
#include <nlohmann/json.hpp>

namespace Mucke {
using Json = nlohmann::json;
struct Station {
    QString id, name, url, radioBrowserID;
    bool enabled = true, favorite = false;
};
struct Group { QString id, name; QStringList stationIDs; };
struct Track {
    QString id, stationID, station, raw, artist, title, sessionID;
    QDateTime receivedAt, endedAt, heardAt, savedAt;
    Json recognition = nullptr;
    bool placeholder = false;
};
struct Recording {
    QString id, file, station, sessionID, ext;
    QDateTime start, end, receivedEnd;
    qint64 bytes = 0;
    bool active = false;
};
enum class PlaybackState { Stopped, Resolving, Buffering, Playing, Paused, Error };
struct PlaybackSnapshot {
    PlaybackState state = PlaybackState::Stopped;
    QString stationID, stationName;
    Track heardTrack;
    int volume = 70;
    bool recordRequested = false, recordActive = false;
    QString recordStatus;
    bool timeshiftEnabled = false, timeshiftAvailable = false, timeshiftPaused = false;
    double bufferSeconds = 0, delaySeconds = 0;
    bool previewActive = false;
    int sleepRemaining = 0;
    QString visualizerStatus, error;
};

enum class SongAudioStatus { Available, Partial, Approximate, MissingBoundaries, MissingFile, ActiveRecording, Unsupported, Failed };
struct RecordingBoundary {
    QString recordingID, trackID, raw;
    qint64 byteOffset = 0;
    QDateTime receivedAt;
    bool captureStart = false, partialStart = false;
};
struct SongExportProposal {
    QString requestID, trackID, recordingID;
    SongAudioStatus status = SongAudioStatus::MissingBoundaries;
    QString explanation;
    double audioStart = 0, audioEnd = 0, suggestedStart = 0, suggestedEnd = 0;
    double startLower = 0, startUpper = 0, endLower = 0, endUpper = 0;
    bool partialStart = false, partialEnd = false;
    QString sourceRevision;
    QJsonObject metadata;
};

QString newID();
bool validStreamURL(const QString &text, QString *reason = nullptr);
QString normalizedStreamURL(const QString &text);
}
Q_DECLARE_METATYPE(Mucke::Station)
Q_DECLARE_METATYPE(QVector<Mucke::Station>)
Q_DECLARE_METATYPE(Mucke::Track)
Q_DECLARE_METATYPE(Mucke::Recording)
Q_DECLARE_METATYPE(Mucke::PlaybackSnapshot)

Q_DECLARE_METATYPE(Mucke::SongExportProposal)
Q_DECLARE_METATYPE(QVector<Mucke::SongExportProposal>)
