#pragma once
#include <vlc/vlc.h>
namespace Mucke::MediaPrivate {
inline void configureRadioPrefetch(libvlc_media_t *media) {
    // Nur für den verifizierten MP3/AAC-Timeshift-Leser: VLC hält sonst zusätzlich
    // 16 MiB Historie. Die Suchhistorie verwaltet hier bereits Timeshift selbst.
    // Einheit: KiB bzw. Bytes. VLC vergrößert den Puffer auf mindestens die Lesegröße.
    libvlc_media_add_option(media, ":prefetch-buffer-size=2048");
    libvlc_media_add_option(media, ":prefetch-read-size=65536");
}
}
