#pragma once
#include "../types.h"
#include <QDir>
#include <QFile>
#include <QRegularExpression>
#include <QTemporaryFile>
#include <atomic>
#include <cerrno>
#include <cmath>
#include <cstring>
#include <unistd.h>
#ifdef Q_OS_LINUX
#include <fcntl.h>
#include <sys/syscall.h>
#endif

namespace Mucke::SongExportFile {
inline QString safeBase(const Track &track) {
    QString name = track.artist.trimmed();
    const QString title = track.title.trimmed().isEmpty() ? track.raw.trimmed() : track.title.trimmed();
    if (!name.isEmpty() && !title.isEmpty())
        name += " - ";
    name += title;
    name.replace(QRegularExpression(QStringLiteral("[\\x00-\\x1f\\x7f/\\\\:*?\"<>|]")), "_");
    name = name.simplified();
    while (name.startsWith('.') || name.startsWith(' '))
        name.remove(0, 1);
    while (name.endsWith('.') || name.endsWith(' '))
        name.chop(1);
    while (name.toUtf8().size() > 160)
        name.chop(1);
    return name.isEmpty() ? QStringLiteral("Mucke") : name;
}
inline bool validRange(const SongExportProposal &p, double startOffset, double endOffset,
                       double fadeIn, double fadeOut) {
    for (double value : {p.audioStart, p.audioEnd, p.suggestedStart, p.suggestedEnd,
                         p.startLower, p.startUpper, p.endLower, p.endUpper,
                         startOffset, endOffset, fadeIn, fadeOut})
        if (!std::isfinite(value))
            return false;
    const double start = p.suggestedStart + startOffset, end = p.suggestedEnd + endOffset;
    return p.audioStart >= 0 && p.audioEnd > p.audioStart && start >= p.audioStart &&
           end <= p.audioEnd && end > start && fadeIn >= 0 && fadeOut >= 0 &&
           fadeIn + fadeOut <= end - start && p.startLower <= p.startUpper &&
           p.endLower <= p.endUpper;
}
struct PublishResult { QString path, error; bool cancelled = false; };
// Die Arbeitsdatei liegt auf dem Ziel-Dateisystem. Das atomare Publizieren ersetzt nie ein Ziel.
inline PublishResult publishExact(const QString &source, const QString &directory, QString base,
                                  const std::atomic_bool &cancelled) {
    auto failure = [](QString error) { return PublishResult{{}, std::move(error), false}; };
    QFile input(source);
    if (!input.open(QIODevice::ReadOnly))
        return failure(input.errorString());
    QTemporaryFile staging(QDir(directory).filePath(".mucke-export-XXXXXX"));
    if (!staging.open())
        return failure(staging.errorString());
    staging.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    QByteArray block(256 * 1024, Qt::Uninitialized);
    while (!input.atEnd()) {
        if (cancelled.load())
            return {{}, {}, true};
        qint64 count = input.read(block.data(), block.size());
        if (count < 0)
            return failure(input.errorString());
        if (count == 0 && !input.atEnd())
            return failure(QStringLiteral("Read failed"));
        qint64 written = 0;
        while (written < count) {
            const qint64 n = staging.write(block.constData() + written, count - written);
            if (n <= 0)
                return failure(staging.errorString());
            written += n;
        }
    }
    if (!staging.flush())
        return failure(staging.errorString());
    staging.close();
    if (base.isEmpty() || base.contains('/') || base.contains('\\') || base.startsWith('.'))
        return failure(QStringLiteral("Invalid filename"));
    const QByteArray temporary = QFile::encodeName(staging.fileName());
    for (int suffix = 1; suffix <= 100000; ++suffix) {
        if (cancelled.load())
            return {{}, {}, true};
        const QString filename = base + (suffix == 1 ? QString() : QString(" (%1)").arg(suffix)) + ".m4a";
        const QString path = QDir(directory).filePath(filename);
        const QByteArray destination = QFile::encodeName(path);
        int result = -1;
#ifdef Q_OS_LINUX
#ifdef SYS_renameat2
        result = int(::syscall(SYS_renameat2, AT_FDCWD, temporary.constData(), AT_FDCWD,
                               destination.constData(), 1 /* RENAME_NOREPLACE */));
        if (result == 0)
            return {path, {}, false};
        if (errno != ENOSYS && errno != EINVAL && errno != EOPNOTSUPP) {
            if (errno == EEXIST)
                continue;
            return failure(QString::fromLocal8Bit(std::strerror(errno)));
        }
#endif
#endif
        result = ::link(temporary.constData(), destination.constData());
        if (result == 0)
            return {path, {}, false};
        if (errno != EEXIST)
            return failure(QString::fromLocal8Bit(std::strerror(errno)));
    }
    return failure(QStringLiteral("Too many filename collisions"));
}
} // namespace Mucke::SongExportFile
