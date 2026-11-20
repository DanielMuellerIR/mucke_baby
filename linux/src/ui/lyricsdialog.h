#pragma once

class QWidget;

namespace Mucke {
struct Track;
void showLyricsDialog(const Track &track, QWidget *parent);
} // namespace Mucke
