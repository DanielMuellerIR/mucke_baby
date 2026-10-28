#pragma once
#include "../types.h"
#include <QRegularExpression>
#include <QUrl>
namespace Mucke::SongTools {
inline QString cleanedTitle(QString title) {
    title.remove(QRegularExpression(
        R"(\s*[\(\[][^\(\)\[\]]*\b(extended|original|radio|club|edit|remix|mix|version|bootleg|vip|instrumental|acoustic|live|remaster[a-z]*)\b[^\(\)\[\]]*[\)\]])",
        QRegularExpression::CaseInsensitiveOption));
    title.remove(QRegularExpression(R"(\s[-–—]\s.*\b(mix|remix|edit|version)\b.*$)",
                                    QRegularExpression::CaseInsensitiveOption));
    return title.trimmed();
}
inline QString cleanedArtist(QString artist) {
    artist.remove(
        QRegularExpression(R"(\s*(\bfeat\.?\b|\bft\.?\b|\bfeaturing\b|\bwith\b|\bvs\.?\b|\bx\b|&|,|/).*$)",
                           QRegularExpression::CaseInsensitiveOption));
    return artist.trimmed();
}
inline QString query(const Track &track) {
    return (track.artist.trimmed() + " " + cleanedTitle(track.title.isEmpty() ? track.raw : track.title))
        .trimmed()
        .left(600);
}
inline QUrl appleMusicURL(const Track &track) {
    return QUrl::fromEncoded("https://music.apple.com/search?term=" + QUrl::toPercentEncoding(query(track)));
}
inline QUrl spotifyURL(const Track &track) {
    return QUrl::fromEncoded("https://open.spotify.com/search/" + QUrl::toPercentEncoding(query(track)));
}
inline QUrl lyricsSearchURL(const Track &track) {
    return QUrl::fromEncoded("https://www.google.com/search?q=" +
                             QUrl::toPercentEncoding(query(track) + " lyrics"));
}
inline QUrl lyricsURL(QString artist, QString title) {
    return QUrl::fromEncoded("https://api.lyrics.ovh/v1/" + QUrl::toPercentEncoding(artist.left(200)) + "/" +
                             QUrl::toPercentEncoding(title.left(200)));
}
inline QVector<QPair<QString, QString>> lyricsQueries(const Track &track) {
    const QString artist = track.artist.trimmed(), title = track.title.trimmed();
    QVector<QPair<QString, QString>> queries;
    for (const auto &pair :
         {qMakePair(artist, cleanedTitle(title)), qMakePair(cleanedArtist(artist), cleanedTitle(title)),
          qMakePair(artist, title), qMakePair(cleanedArtist(artist), title)})
        if (!pair.first.isEmpty() && !pair.second.isEmpty() && !queries.contains(pair))
            queries.append(pair);
    return queries;
}
} // namespace Mucke::SongTools
