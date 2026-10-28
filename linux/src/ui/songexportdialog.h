#pragma once
#include "../types.h"

class QWidget;
namespace Mucke {
class MediaEngine;
// Öffnet einen modalen Dialog; maximal 100 Titel werden in einem Vorbereitungslauf untersucht.
void showSongExportDialog(QVector<Track> tracks, MediaEngine *media, QWidget *parent = nullptr);
}
