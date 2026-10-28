#include <vlc/vlc.h>
#include <atomic>
#include <chrono>
#include <cstring>
#include <iostream>
#include <thread>
struct Probe { std::atomic<unsigned> rate{0}; std::atomic<bool> timeEvent{false}, ended{false}; };
static int format(void **opaque, char *fourcc, unsigned *rate, unsigned *channels) {
    auto *probe = static_cast<Probe *>(*opaque); probe->rate = *rate; std::memcpy(fourcc, "S16N", 4); *channels = 2; return 0;
}
static void audio(void *, const void *, unsigned, int64_t) {}
static void event(const libvlc_event_t *event, void *opaque) {
    auto *probe = static_cast<Probe *>(opaque);
    if (event->type == libvlc_MediaPlayerTimeChanged) probe->timeEvent = true;
    if (event->type == libvlc_MediaPlayerEndReached || event->type == libvlc_MediaPlayerEncounteredError) probe->ended = true;
}
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    const char *options[]{"--ignore-config", "--no-video", "--quiet", "--no-audio-time-stretch"};
    auto *instance = libvlc_new(4, options); if (!instance) return 2;
    auto *media = libvlc_media_new_path(instance, argv[1]); auto *player = libvlc_media_player_new_from_media(media);
    Probe probe; libvlc_audio_set_callbacks(player, audio, nullptr, nullptr, nullptr, nullptr, &probe); libvlc_audio_set_format_callbacks(player, format, nullptr);
    auto *manager = libvlc_media_player_event_manager(player);
    for (auto type : {libvlc_MediaPlayerTimeChanged, libvlc_MediaPlayerEndReached, libvlc_MediaPlayerEncounteredError}) libvlc_event_attach(manager, type, event, &probe);
    libvlc_media_player_play(player); unsigned trackRate = 0;
    for (int i = 0; i < 40; ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        libvlc_media_track_t **tracks = nullptr; unsigned count = libvlc_media_tracks_get(media, &tracks);
        for (unsigned j = 0; j < count; ++j) if (tracks[j]->i_type == libvlc_track_audio && tracks[j]->audio) {
            trackRate = tracks[j]->audio->i_rate;
            std::cout << "trackRate=" << trackRate << " actualFormatRate=" << probe.rate << " profile=" << tracks[j]->i_profile << " channels=" << tracks[j]->audio->i_channels << " afterTimeEvent=" << probe.timeEvent << '\n';
        }
        libvlc_media_tracks_release(tracks, count);
        if (probe.rate && probe.timeEvent) break;
    }
    libvlc_media_player_stop(player); libvlc_media_player_release(player); libvlc_media_release(media); libvlc_release(instance);
    return trackRate && probe.rate && probe.timeEvent ? (trackRate == probe.rate ? 0 : 1) : 3;
}
