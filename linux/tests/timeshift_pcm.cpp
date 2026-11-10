#include "media/timeshift.h"
#include "media/radioprefetch.h"
#include <QCoreApplication>
#include <QTemporaryDir>
#include <vlc/vlc.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

struct Input { std::vector<unsigned char> data; size_t pos = 0; };
static int openInput(void *opaque, void **out, uint64_t *size) { *out = opaque; *size = UINT64_MAX; return 0; }
static ssize_t readInput(void *opaque, unsigned char *out, size_t count) {
    auto &s = *static_cast<Input *>(opaque);
    count = std::min(count, s.data.size() - s.pos);
    memcpy(out, s.data.data() + s.pos, count); s.pos += count; return ssize_t(count);
}
static void closeInput(void *) {}
struct ClockSample { size_t frames; int64_t pts, vlcTime; };
struct PlaybackClock { int64_t now, vlcTime; };
struct Output {
    std::vector<int16_t> pcm;
    std::vector<ClockSample> clock;
    std::vector<PlaybackClock> playbackClock;
    std::atomic<bool> ended{false};
    std::mutex mutex;
    libvlc_media_player_t *player = nullptr;
    unsigned decodedRate = 0, decodedChannels = 0;
    std::atomic<int64_t> endPTS{0};
    int formatChanges = 0;
};
static int format(void **opaque, char *fourcc, unsigned *rate, unsigned *channels) {
    auto &s = *static_cast<Output *>(*opaque);
    if (s.decodedRate && (s.decodedRate != *rate || s.decodedChannels != *channels)) ++s.formatChanges;
    s.decodedRate = *rate; s.decodedChannels = *channels;
    memcpy(fourcc, "S16N", 4); *channels = 2;
    return 0;
}
static void play(void *opaque, const void *samples, unsigned count, int64_t pts) {
    auto &s = *static_cast<Output *>(opaque);
    std::lock_guard<std::mutex> lock(s.mutex);
    s.clock.push_back({s.pcm.size() / 2, pts, libvlc_media_player_get_time(s.player)});
    const auto *p = static_cast<const int16_t *>(samples);
    s.pcm.insert(s.pcm.end(), p, p + count * 2);
    s.endPTS = pts + int64_t(count) * 1000000 / s.decodedRate;
}
static void drain(void *opaque) {
    auto &s = *static_cast<Output *>(opaque);
    while (libvlc_clock() < s.endPTS.load()) std::this_thread::sleep_for(std::chrono::milliseconds(5));
}
static void event(const libvlc_event_t *e, void *opaque) {
    if (e->type == libvlc_MediaPlayerEndReached || e->type == libvlc_MediaPlayerEncounteredError)
        static_cast<Output *>(opaque)->ended = true;
}
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    if (argc == 2 && std::string(argv[1]) == "--version") { std::puts(libvlc_get_version()); return 0; }
    if (argc < 5) return 2; // input, output, callback/file, demux, media options...
    const char *options[] = {"--no-video", "--no-metadata-network-access", "--no-audio-time-stretch", "--quiet", "--no-plugins-cache"};
    auto *vlc = libvlc_new(5, options); if (!vlc) return 3;
    Input input;
    std::ifstream f(argv[1], std::ios::binary);
    input.data.assign(std::istreambuf_iterator<char>(f), {});
    QTemporaryDir cache;
    std::unique_ptr<Mucke::MediaPrivate::TimeshiftBuffer> buffer;
    std::shared_ptr<Mucke::MediaPrivate::TimeshiftReader> reader;
    libvlc_media_t *media = nullptr;
    double firstReadyLive = 0, firstReadyOldest = 0;
    if (std::string(argv[3]) == "buffer" || std::string(argv[3]) == "initial") {
        if (argc < 9 || !cache.isValid()) return 6;
        Mucke::MediaPrivate::TimeshiftLimits limits; limits.minimumFreeBytes = 0;
        buffer = std::make_unique<Mucke::MediaPrivate::TimeshiftBuffer>(cache.path(), limits);
        const bool aac = std::string(argv[4]) == "aac";
        const Mucke::MediaPrivate::DecoderProfile profile{aac ? "aac" : "mp3", std::atoi(argv[6]), std::atoi(argv[7]), true};
        if (!buffer->begin(aac ? "audio/aac" : "audio/mpeg", "pcm-gate", profile)) return 7;
        const QByteArray all(reinterpret_cast<const char *>(input.data.data()), input.data.size());
        const int marker = std::atoi(argv[8]);
        Mucke::Track track; track.id = "440"; track.raw = "440";
        buffer->noteTitle(track);
        const bool initial = std::string(argv[3]) == "initial";
        const int initialBytes = initial && argc > 9 ? std::atoi(argv[9]) : 0;
        if (initial) {
            if (!buffer->append(all.left(initialBytes), QDateTime::fromMSecsSinceEpoch(1000))) return buffer->view().phase == Mucke::MediaPrivate::BufferPhase::Unsupported ? 11 : 8;
            firstReadyLive = buffer->view().live; firstReadyOldest = buffer->view().oldest;
            reader = buffer->readerLive();
            if (!reader) return 9;
        }
        if (!buffer->append(all.mid(initialBytes, marker-initialBytes), QDateTime::fromMSecsSinceEpoch(1000))) return buffer->view().phase == Mucke::MediaPrivate::BufferPhase::Unsupported ? 11 : 8;
        track.id = "880"; track.raw = "880"; buffer->noteTitle(track);
        if (!buffer->append(all.mid(marker), QDateTime::fromMSecsSinceEpoch(2000))) return buffer->view().phase == Mucke::MediaPrivate::BufferPhase::Unsupported ? 11 : 8;
        if (!initial) reader = buffer->readerAt(std::atof(argv[5]));
        if (!reader) return 9;
        buffer->endReception();
        media = reader->createMedia(vlc);
    } else {
        media = std::string(argv[3]) == "callback"
            ? libvlc_media_new_callbacks(vlc, openInput, readInput, nullptr, closeInput, &input)
            : libvlc_media_new_path(vlc, argv[1]);
        const auto demux = ":demux=" + std::string(argv[4]);
        libvlc_media_add_option(media, demux.c_str());
        for (int i = 5; i < argc; ++i) libvlc_media_add_option(media, argv[i]);
    }
    if (!media) return 10;
    if (buffer) Mucke::MediaPrivate::configureRadioPrefetch(media);
    auto *player = libvlc_media_player_new_from_media(media);
    Output out; out.player = player;
    libvlc_audio_set_callbacks(player, play, nullptr, nullptr, nullptr, drain, &out);
    libvlc_audio_set_format_callbacks(player, format, nullptr);
    auto *events = libvlc_media_player_event_manager(player);
    libvlc_event_attach(events, libvlc_MediaPlayerEndReached, event, &out);
    libvlc_event_attach(events, libvlc_MediaPlayerEncounteredError, event, &out);
    if (libvlc_media_player_play(player) < 0) return 4;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(40);
    while (!out.ended && std::chrono::steady_clock::now() < deadline) {
        out.playbackClock.push_back({libvlc_clock(), libvlc_media_player_get_time(player)});
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    if (reader) reader->cancel();
    libvlc_media_player_stop(player);
    libvlc_media_player_release(player); libvlc_media_release(media); libvlc_release(vlc);
    std::ofstream result(argv[2], std::ios::binary);
    result.write(reinterpret_cast<const char *>(out.pcm.data()), out.pcm.size() * sizeof(int16_t));
    std::ofstream metadata(std::string(argv[2]) + ".json");
    metadata << std::setprecision(17) << "{\"decodedRate\":" << out.decodedRate << ",\"decodedChannels\":" << out.decodedChannels
             << ",\"firstReadyLive\":" << firstReadyLive << ",\"firstReadyOldest\":" << firstReadyOldest
             << ",\"inputStart\":" << (reader ? reader->inputStart() : 0)
             << ",\"outputStart\":" << (reader ? reader->outputStart() : 0)
             << ",\"titleBefore\":\"" << (buffer ? buffer->trackAt(5.5).raw.toStdString() : "") << "\""
             << ",\"titleAfter\":\"" << (buffer ? buffer->trackAt(6.5).raw.toStdString() : "") << "\""
             << ",\"formatChanges\":" << out.formatChanges << ",\"frames\":" << out.pcm.size() / 2 << ",\"clock\":[";
    bool first = true;
    for (const auto &sample : out.clock) {
        if (!first) metadata << ',';
        first = false;
        metadata << "{\"frames\":" << sample.frames << ",\"pts\":" << sample.pts << ",\"vlcTime\":" << sample.vlcTime << '}';
    }
    metadata << "],\"playbackClock\":[";
    first = true;
    for (const auto &sample : out.playbackClock) {
        if (!first) metadata << ',';
        first = false;
        metadata << "{\"now\":" << sample.now << ",\"vlcTime\":" << sample.vlcTime << '}';
    }
    metadata << "]}\n";
    fprintf(stderr, "frames=%zu decodedRate=%u channels=%u ended=%d\n", out.pcm.size()/2, out.decodedRate, out.decodedChannels, int(out.ended.load()));
    return out.ended && out.decodedRate && !out.formatChanges ? 0 : 5;
}
