#include "streamprotocol.h"
#include "../types.h"
#include <QRegularExpression>
#include <QStringConverter>
#include <QXmlStreamReader>
#include <iconv.h>
#include <cerrno>
#include <algorithm>
namespace Mucke::MediaPrivate {
QString decodeText(const QByteArray &bytes) {
    QStringDecoder utf8(QStringDecoder::Utf8);
    QString text = utf8(bytes);
    if (!utf8.hasError()) return text;
    iconv_t converter = iconv_open("UTF-8", "CP932");
    if (converter != reinterpret_cast<iconv_t>(-1)) {
        QByteArray output(bytes.size() * 4 + 4, '\0');
        char *input = const_cast<char *>(bytes.constData()), *destination = output.data();
        size_t left = size_t(bytes.size()), available = size_t(output.size());
        const bool ok = iconv(converter, &input, &left, &destination, &available) != size_t(-1) && left == 0;
        iconv_close(converter);
        if (ok) return QString::fromUtf8(output.constData(), output.size() - qsizetype(available));
    }
    return QString::fromLatin1(bytes);
}
bool needsResolution(const QUrl &url) {
    const QString path = url.path().toLower();
    if (path.endsWith(".m3u8")) return false;
    for (const QString &suffix : {QString(".pls"), QString(".m3u"), QString(".asx"), QString(".xspf")})
        if (path.endsWith(suffix)) return true;
    return path.contains("tune.ashx") || path.contains("/pls");
}
QUrl playlistTarget(const QByteArray &bytes) {
    if (bytes.size() > 65536) return {};
    if (bytes.startsWith(QByteArray::fromHex("0000feff")) || bytes.startsWith(QByteArray::fromHex("fffe0000"))
        || bytes.startsWith(QByteArray::fromHex("0000003c")) || bytes.startsWith(QByteArray::fromHex("3c000000"))) return {};
    QString decoded;
    if (bytes.startsWith(QByteArray::fromHex("feff")) || bytes.startsWith(QByteArray::fromHex("003c"))) {
        QStringDecoder decoder(QStringDecoder::Utf16BE); decoded = decoder(bytes); if (decoder.hasError()) return {};
    } else if (bytes.startsWith(QByteArray::fromHex("fffe")) || bytes.startsWith(QByteArray::fromHex("3c00"))) {
        QStringDecoder decoder(QStringDecoder::Utf16LE); decoded = decoder(bytes); if (decoder.hasError()) return {};
    } else decoded = decodeText(bytes);
    const QString text = decoded.trimmed().remove(QChar(0xfeff));
    auto accepted = [](QString value) { value = value.trimmed(); return validStreamURL(value) ? QUrl(value) : QUrl(); };
    if (text.startsWith('<')) {
        if (text.contains("<!DOCTYPE", Qt::CaseInsensitive) || text.contains("<!ENTITY", Qt::CaseInsensitive)) return {};
        QXmlStreamReader reader(text);
        QStringList path, namespaces;
        QUrl result;
        while (!reader.atEnd()) {
            reader.readNext();
            if (reader.isStartElement()) {
                path.append(reader.name().toString().toLower());
                namespaces.append(reader.namespaceUri().toString());
                const bool noNamespaces = std::all_of(namespaces.begin(), namespaces.end(), [](const QString &v) { return v.isEmpty(); });
                if ((path == QStringList{"asx", "entry", "ref"} || path == QStringList{"asx", "repeat", "entry", "ref"}) && noNamespaces) {
                    for (const auto &attribute : reader.attributes())
                        if (attribute.name().compare(QString("href"), Qt::CaseInsensitive) == 0 && result.isEmpty()) result = accepted(attribute.value().toString());
                }
                const bool xspf = path == QStringList{"playlist", "tracklist", "track", "location"}
                    && std::all_of(namespaces.begin(), namespaces.end(), [&](const QString &v) { return v == namespaces.first() && (v.isEmpty() || v == "http://xspf.org/ns/0/"); });
                if (xspf) {
                    QUrl candidate = accepted(reader.readElementText(QXmlStreamReader::ErrorOnUnexpectedElement));
                    if (result.isEmpty()) result = candidate;
                    path.removeLast(); namespaces.removeLast();
                }
            } else if (reader.isEndElement()) {
                if (path.isEmpty()) return {};
                path.removeLast(); namespaces.removeLast();
            }
        }
        return reader.hasError() ? QUrl() : result;
    }
    static const QRegularExpression fileKey("^File[0-9]+\\s*=\\s*(.*)$", QRegularExpression::CaseInsensitiveOption);
    const QStringList lines = text.split(QRegularExpression("[\\r\\n]+"));
    for (QString line : lines) {
        auto match = fileKey.match(line.trimmed());
        if (match.hasMatch()) { QUrl url = accepted(match.captured(1)); if (!url.isEmpty()) return url; }
    }
    for (QString line : lines) {
        line = line.trimmed();
        if (line.startsWith('#') || line.startsWith('[')) continue;
        QUrl url = accepted(line); if (!url.isEmpty()) return url;
    }
    return {};
}
bool isHLS(const QString &type, const QUrl &url) {
    const QString mime = type.section(';', 0, 0).trimmed().toLower();
    return url.path().endsWith(".m3u8", Qt::CaseInsensitive) || mime == "application/vnd.apple.mpegurl"
        || mime == "application/x-mpegurl" || mime == "audio/mpegurl" || mime == "audio/x-mpegurl";
}
QString safeExportName(QString text) {
    text.replace(QRegularExpression("[\\x00-\\x1f\\x7f/\\\\:]"), "_");
    text = text.trimmed();
    while (text.startsWith('.')) text.remove(0, 1);
    if (text.isEmpty()) text = "recording";
    return text.left(180);
}
ICYParser::ICYParser(int value) : interval(std::clamp(value, 0, 16 * 1024 * 1024)), audioLeft(interval) {}
void ICYParser::feed(const QByteArray &bytes, const std::function<void(const QByteArray &)> &audio,
                     const std::function<void(const QString &)> &title) {
    if (interval == 0) { if (!bytes.isEmpty()) audio(bytes); return; }
    qsizetype offset = 0;
    while (offset < bytes.size()) {
        if (audioLeft > 0) {
            const int count = int(std::min<qsizetype>(audioLeft, bytes.size() - offset));
            audio(bytes.mid(offset, count)); offset += count; audioLeft -= count;
        } else if (metadataLeft < 0) {
            metadataLeft = int(static_cast<unsigned char>(bytes[offset++])) * 16;
            metadata.clear();
            if (metadataLeft == 0) { audioLeft = interval; metadataLeft = -1; }
        } else {
            const int count = int(std::min<qsizetype>(metadataLeft, bytes.size() - offset));
            metadata.append(bytes.constData() + offset, count); offset += count; metadataLeft -= count;
            if (metadataLeft == 0) {
                const QString text = decodeText(metadata).remove(QChar(0));
                static const QRegularExpression field("(?:^|;)\\s*StreamTitle\\s*=\\s*(['\"])(.*?)\\1\\s*(?:;|$)", QRegularExpression::CaseInsensitiveOption);
                const auto match = field.match(text);
                if (match.hasMatch()) {
                    QString value = match.captured(2).trimmed().left(4096);
                    if (!value.isEmpty() && value != lastTitle) { lastTitle = value; title(value); }
                }
                audioLeft = interval; metadataLeft = -1; metadata.clear();
            }
        }
    }
}
}
