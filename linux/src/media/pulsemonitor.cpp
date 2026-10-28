#include "pulsemonitor.h"
#include <QElapsedTimer>
#include <QLocale>
#include <QTimer>
#include <pulse/pulseaudio.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <complex>
#include <cstring>
#include <unistd.h>
namespace Mucke::MediaPrivate {
namespace {
QString text(const char *en, const char *de) { return QString::fromUtf8(QLocale().language() == QLocale::German ? de : en); }
}
class PulseMonitor::Impl {
public:
    PulseMonitor *owner;
    pa_mainloop *loop = nullptr;
    pa_context *context = nullptr;
    pa_stream *stream = nullptr;
    QTimer timer;
    QElapsedTimer clock;
    bool enabled = false, scanning = false, subscribed = false;
    int matches = 0;
    quint64 changes = 0, scanChanges = 0;
    uint32_t selected = PA_INVALID_INDEX, candidate = PA_INVALID_INDEX, candidateSink = PA_INVALID_INDEX;
    qint64 lastScan = -3000, lastFrame = -100;
    std::array<float, 1024> samples{};
    size_t sampleCount = 0;
    QString lastStatus;
    explicit Impl(PulseMonitor *object) : owner(object) {
        timer.setInterval(16); clock.start();
        QObject::connect(&timer, &QTimer::timeout, owner, [this] { tick(); });
    }
    ~Impl() { close(); }
    void message(QString value) { if (value != lastStatus) { lastStatus = value; if (owner->status) owner->status(value); } }
    void disconnectStream() {
        if (stream) { pa_stream_set_read_callback(stream, nullptr, nullptr); pa_stream_set_state_callback(stream, nullptr, nullptr); pa_stream_disconnect(stream); pa_stream_unref(stream); stream = nullptr; }
        selected = PA_INVALID_INDEX; sampleCount = 0;
    }
    void close() {
        timer.stop(); disconnectStream();
        if (context) { pa_context_set_state_callback(context, nullptr, nullptr); pa_context_disconnect(context); pa_context_unref(context); context = nullptr; }
        if (loop) { pa_mainloop_free(loop); loop = nullptr; }
        scanning = false; subscribed = false;
    }
    void setActive(bool value) {
        if (value == enabled && (!value || context)) return;
        enabled = value;
        if (!enabled) { close(); message(text("Visualizer inactive", "Visualizer inaktiv")); return; }
        if (context) return;
        loop = pa_mainloop_new();
        if (!loop) return;
        pa_proplist *properties = pa_proplist_new(); pa_proplist_sets(properties, PA_PROP_APPLICATION_NAME, "Mucke, Baby! Visualizer");
        context = pa_context_new_with_proplist(pa_mainloop_get_api(loop), "Mucke, Baby! private monitor", properties); pa_proplist_free(properties);
        if (!context || pa_context_connect(context, nullptr, PA_CONTEXT_NOAUTOSPAWN, nullptr) < 0) { close(); message(text("PulseAudio monitor unavailable", "PulseAudio-Monitor nicht verfügbar")); return; }
        lastScan = -3000; timer.start();
    }
    void tick() {
        if (!context) return;
        // Nicht blockieren: Pulse und Qt laufen auf demselben seriellen Worker.
        for (int i = 0; i < 8; ++i) { int result = pa_mainloop_iterate(loop, 0, nullptr); if (result <= 0) break; }
        const pa_context_state_t state = pa_context_get_state(context);
        if (state == PA_CONTEXT_FAILED || state == PA_CONTEXT_TERMINATED) { close(); message(text("PulseAudio connection lost; visualizer paused", "PulseAudio-Verbindung verloren; Visualizer ruht")); return; }
        if (state == PA_CONTEXT_READY && !subscribed) {
            pa_context_set_subscribe_callback(context, [](pa_context *, pa_subscription_event_type_t event, uint32_t, void *data) {
                auto *self = static_cast<Impl *>(data);
                if ((event & PA_SUBSCRIPTION_EVENT_FACILITY_MASK) == PA_SUBSCRIPTION_EVENT_SINK_INPUT) {
                    ++self->changes;
                    self->lastScan = -3000;
                    // Die bisherige Zuordnung verliert bis zur erneuten Eindeutigkeitsprüfung ihre Gültigkeit.
                    self->disconnectStream();
                }
            }, this);
            pa_operation *operation = pa_context_subscribe(context, PA_SUBSCRIPTION_MASK_SINK_INPUT, nullptr, nullptr);
            if (operation) pa_operation_unref(operation);
            subscribed = true;
        }
        if (state != PA_CONTEXT_READY || scanning || clock.elapsed() - lastScan < 1500) return;
        scanning = true; scanChanges = changes; matches = 0; candidate = candidateSink = PA_INVALID_INDEX; lastScan = clock.elapsed();
        pa_operation *operation = pa_context_get_sink_input_info_list(context, &Impl::sinkInput, this);
        if (operation) pa_operation_unref(operation); else scanning = false;
    }
    static void sinkInput(pa_context *context, const pa_sink_input_info *info, int end, void *data) {
        auto *self = static_cast<Impl *>(data);
        if (end) {
            if (end < 0 || self->matches != 1 || self->scanChanges != self->changes) {
                self->scanning = false; self->disconnectStream();
                self->message(text("Visualizer paused: application audio output is absent or ambiguous", "Visualizer ruht: Anwendungsausgang fehlt oder ist nicht eindeutig")); return;
            }
            if (self->selected == self->candidate && self->stream) { self->scanning = false; return; }
            pa_operation *operation = pa_context_get_sink_info_by_index(context, self->candidateSink, &Impl::sinkInfo, self);
            if (operation) pa_operation_unref(operation); else self->scanning = false;
            return;
        }
        if (!info || !info->proplist) return;
        const char *pid = pa_proplist_gets(info->proplist, PA_PROP_APPLICATION_PROCESS_ID);
        if (pid && QByteArray(pid) == QByteArray::number(::getpid())) { ++self->matches; self->candidate = info->index; self->candidateSink = info->sink; }
    }
    static void sinkInfo(pa_context *, const pa_sink_info *info, int end, void *data) {
        auto *self = static_cast<Impl *>(data);
        if (end) { self->scanning = false; return; }
        if (!info || !info->monitor_source_name || self->matches != 1 || self->scanChanges != self->changes) return;
        self->disconnectStream();
        const pa_sample_spec spec{PA_SAMPLE_FLOAT32NE, 48000, 1};
        self->stream = pa_stream_new(self->context, "Private visualizer", &spec, nullptr);
        if (!self->stream) return;
        // Nur dieses eine Sinkinput abonnieren. Ohne set_monitor_stream niemals einen globalen Monitor öffnen.
        if (pa_stream_set_monitor_stream(self->stream, self->candidate) < 0) { self->disconnectStream(); return; }
        pa_stream_set_read_callback(self->stream, &Impl::read, self);
        pa_stream_set_state_callback(self->stream, &Impl::streamState, self);
        pa_buffer_attr buffer{}; buffer.maxlength = 32768; buffer.fragsize = 4096; buffer.tlength = buffer.prebuf = buffer.minreq = uint32_t(-1);
        if (pa_stream_connect_record(self->stream, info->monitor_source_name, &buffer, pa_stream_flags_t(PA_STREAM_DONT_MOVE | PA_STREAM_ADJUST_LATENCY)) < 0) { self->disconnectStream(); return; }
        self->selected = self->candidate;
    }
    static void streamState(pa_stream *stream, void *data) {
        auto *self = static_cast<Impl *>(data);
        const auto state = pa_stream_get_state(stream);
        if (state == PA_STREAM_READY) self->message(text("Private application audio monitor", "Privater Audio-Monitor der Anwendung"));
        else if (state == PA_STREAM_FAILED || state == PA_STREAM_TERMINATED) self->message(text("Private monitor unavailable; visualizer paused", "Privater Monitor nicht verfügbar; Visualizer ruht"));
    }
    static void read(pa_stream *stream, size_t, void *data) {
        auto *self = static_cast<Impl *>(data);
        for (int iteration = 0; iteration < 8; ++iteration) {
            const void *bytes = nullptr; size_t length = 0;
            if (pa_stream_peek(stream, &bytes, &length) < 0 || length == 0) break;
            const size_t count = length / sizeof(float); const auto *values = static_cast<const float *>(bytes);
            const size_t begin = count > self->samples.size() ? count - self->samples.size() : 0;
            for (size_t i = begin; i < count; ++i) {
                const float value = values && std::isfinite(values[i]) ? std::clamp(values[i], -1.0f, 1.0f) : 0;
                self->samples[self->sampleCount++ % self->samples.size()] = value;
            }
            pa_stream_drop(stream);
        }
        if (self->clock.elapsed() - self->lastFrame >= 34 && self->sampleCount >= self->samples.size()) self->emitFrame();
    }
    void emitFrame() {
        lastFrame = clock.elapsed();
        QVector<float> waveform(256), spectrum(128); float square = 0;
        std::array<std::complex<float>, 1024> fft{};
        for (size_t i = 0; i < samples.size(); ++i) {
            const float value = samples[(sampleCount + i) % samples.size()]; square += value * value;
            fft[i] = value * float(0.5 - 0.5 * std::cos(2 * M_PI * i / (samples.size() - 1)));
            if (i % 4 == 0) waveform[int(i / 4)] = value;
        }
        for (size_t i = 1, j = 0; i < fft.size(); ++i) { size_t bit = fft.size() >> 1; for (; j & bit; bit >>= 1) j ^= bit; j ^= bit; if (i < j) std::swap(fft[i], fft[j]); }
        for (size_t length = 2; length <= fft.size(); length <<= 1) {
            const std::complex<float> base(std::cos(-2 * M_PI / length), std::sin(-2 * M_PI / length));
            for (size_t start = 0; start < fft.size(); start += length) {
                std::complex<float> factor(1, 0);
                for (size_t j = 0; j < length / 2; ++j) { auto even = fft[start + j], odd = fft[start + j + length / 2] * factor; fft[start + j] = even + odd; fft[start + j + length / 2] = even - odd; factor *= base; }
            }
        }
        for (int i = 0; i < spectrum.size(); ++i) spectrum[i] = std::clamp(std::abs(fft[size_t(i + 1)]) / 256.0f, 0.0f, 1.0f);
        if (owner->frames) owner->frames(waveform, spectrum, std::sqrt(square / samples.size()));
    }
};
PulseMonitor::PulseMonitor(QObject *parent) : QObject(parent), d(std::make_unique<Impl>(this)) {}
PulseMonitor::~PulseMonitor() = default;
void PulseMonitor::setActive(bool value) { d->setActive(value); }
}
