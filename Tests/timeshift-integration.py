#!/usr/bin/env python3
"""Zeitversatz mit echten ICY-, Recorder-, Export- und Fensterpfaden.

prepare ROOT baut einen isolierten Prüfhost. run ROOT gehört ausschließlich in
die Ressourcen-FIFO; cleanup ROOT beendet nur die belegten eigenen Prozesse.
"""
import argparse
import array
import bisect
import functools
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import threading
import time
import urllib.request
import uuid


def common():
    spec = importlib.util.spec_from_file_location('transport', Path(__file__).with_name('timeshift-transport.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def prepare(root):
    common().prepare(root)
    fixture = root / 'fixtures'
    fixture.mkdir()
    formats = {}
    for name, ext, encoder, options, mime in [
        ('mp3', 'mp3', 'libmp3lame', ['-b:a', '128k', '-write_xing', '0', '-id3v2_version', '0'], 'audio/mpeg'),
        ('aac', 'aac', 'aac', ['-b:a', '128k', '-f', 'adts'], 'audio/aac'),
        ('vorbis', 'ogg', 'vorbis', ['-strict', 'experimental'], 'audio/ogg'),
        ('opus', 'opus', 'opus', ['-strict', 'experimental'], 'audio/opus'),
        ('flac', 'flac', 'flac', [], 'audio/flac')
    ]:
        target = fixture / (name + '.' + ext)
        subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i',
            r'aevalsrc=0.12*sin(2*PI*if(lt(mod(t\,60)\,30)\,440\,880)*t):s=48000:d=96',
            '-ac', '2', '-c:a', encoder, *options, str(target)], check=True, timeout=60)
        packets = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'a',
            '-show_packets', '-show_entries', 'packet=pos,pts_time,duration_time', '-of', 'json', str(target)]))['packets']
        duration = max(float(p.get('pts_time', 0)) + float(p.get('duration_time', 0)) for p in packets)
        formats[name] = dict(file=target.name, mime=mime, duration=duration,
            packets=[(int(p['pos']), float(p.get('pts_time', 0))) for p in packets if p.get('pos') is not None])
    he_wave = fixture / 'he-source.wav'
    subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i',
        r'aevalsrc=0.12*sin(2*PI*if(lt(mod(t\,60)\,30)\,440\,880)*t):s=48000:d=96',
        '-ac', '2', str(he_wave)], check=True, timeout=60)
    he_file = fixture / 'heaac.aac'
    subprocess.run(['afconvert', '-f', 'adts', '-d', 'aach@48000', '-b', '48000', str(he_wave), str(he_file)], check=True, timeout=60)
    packets = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'a',
        '-show_packets', '-show_entries', 'packet=pos,pts_time,duration_time', '-of', 'json', str(he_file)]))['packets']
    formats['heaac'] = dict(file=he_file.name, mime='audio/aacp',
        duration=max(float(p.get('pts_time', 0)) + float(p.get('duration_time', 0)) for p in packets),
        packets=[(int(p['pos']), float(p.get('pts_time', 0))) for p in packets])
    for codec, encoder, options, mime in [('mp3', 'libmp3lame', ['-write_xing', '0', '-id3v2_version', '0'], 'audio/mpeg'),
                                         ('aac', 'aac', ['-f', 'adts'], 'audio/aac')]:
        name = 'effects-' + codec
        target = fixture / (name + '.' + codec)
        subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i',
            'aevalsrc=0.05*(sin(2*PI*125*t)+sin(2*PI*1000*t)+sin(2*PI*8000*t)):s=48000:d=16',
            '-ac', '2', '-c:a', encoder, '-b:a', '192k', *options, str(target)], check=True, timeout=60)
        formats[name] = dict(file=target.name, mime=mime, duration=16, packets=[])
    (root / 'formats.json').write_text(json.dumps(formats))
    hls = fixture / 'hls'
    hls.mkdir()
    subprocess.run(['ffmpeg', '-v', 'error', '-i', str(fixture / 'aac.aac'), '-c', 'copy', '-f', 'hls',
        '-hls_time', '2', '-hls_playlist_type', 'vod', str(hls / 'index.m3u8')], check=True, timeout=60)
    shutil.copy(__file__, root / 'runner.py')
    shutil.copy(Path(__file__).with_name('timeshift-transport.py'), root / 'timeshift-transport.py')


def serve(root):
    formats = json.loads((root / 'formats.json').read_text())
    audio = {name: (root / 'fixtures' / entry['file']).read_bytes() for name, entry in formats.items()}
    lock = threading.Lock()
    active, events = {}, []
    drop = 0

    class Handler(SimpleHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, *_):
            pass

        def response(self, body, mime='application/json'):
            self.send_response(200)
            self.send_header('Content-Type', mime)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            nonlocal drop
            if self.path == '/stats':
                with lock:
                    body = json.dumps(dict(active=active, events=events)).encode()
                self.response(body)
                return
            if self.path == '/control/drop':
                with lock:
                    drop += 1
                self.response(b'{}')
                return
            capture = self.headers.get('User-Agent') == 'MuckeBaby/1.0'
            name = self.path.strip('/')
            if name not in formats:
                with lock:
                    events.append(dict(event='request', path=self.path, capture=capture))
                if self.path == '/manifest':
                    lines = (root / 'fixtures/hls/index.m3u8').read_text().splitlines()
                    body = '\n'.join(line if line.startswith('#') else 'hls/' + line for line in lines).encode()
                    self.response(body, 'application/vnd.apple.mpegurl')
                else:
                    super().do_GET()
                return
            identifier = uuid.uuid4().hex
            data, entry = audio[name], formats[name]
            positions = [int(packet[0]) for packet in entry['packets']]
            def media_time(offset):
                if name in ['mp3', 'aac', 'heaac']:
                    index = max(0, bisect.bisect_right(positions, offset) - 1)
                    return entry['packets'][index][1]
                return offset / len(data) * entry['duration']
            icy = self.headers.get('Icy-MetaData') == '1'
            with lock:
                epoch = drop
                active[identifier] = dict(format=name, capture=capture, audioBytes=0)
                events.append(dict(event='open', id=identifier, format=name, capture=capture, at=time.monotonic()))
            try:
                self.send_response(200)
                self.send_header('Content-Type', entry['mime'])
                self.send_header('Connection', 'close')
                if icy:
                    self.send_header('icy-metaint', '4096')
                self.end_headers()
                start = time.monotonic()
                offset, cycles = 0, 0
                while True:
                    with lock:
                        if capture and drop != epoch:
                            break
                    packet = bytearray()
                    while len(packet) < 4096:
                        length = min(4096 - len(packet), len(data) - offset)
                        packet.extend(data[offset:offset + length])
                        offset += length
                        if offset == len(data):
                            offset = 0
                            cycles += 1
                    if icy:
                        hz = 440 if int(media_time(offset) / 30) % 2 == 0 else 880
                        title = f"StreamTitle='Fixture - Tone {hz}';".encode()
                        blocks = (len(title) + 15) // 16
                        packet.extend(bytes([blocks]) + title.ljust(blocks * 16, b'\0'))
                    self.wfile.write(packet)
                    self.wfile.flush()
                    with lock:
                        active[identifier]['audioBytes'] += 4096
                    deadline = start + cycles * entry['duration'] + media_time(offset)
                    time.sleep(max(0, deadline - time.monotonic()))
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                self.close_connection = True
                with lock:
                    active.pop(identifier, None)
                    events.append(dict(event='close', id=identifier, at=time.monotonic()))

    server = ThreadingHTTPServer(('127.0.0.1', 0),
        functools.partial(Handler, directory=str(root / 'fixtures')))
    server.daemon_threads = True
    (root / 'server.json').write_text(json.dumps(dict(port=server.server_port)))
    server.serve_forever()


def run(root):
    helper = common()
    ax = Path(os.environ['MUCKE_AX_TOOL'])
    server = subprocess.Popen([os.sys.executable, str(root / 'runner.py'), 'serve', str(root)])
    helper.track(root, server, 'server', root / 'runner.py')
    try:
        helper.wait(lambda: (root / 'server.json').exists())
        base = 'http://127.0.0.1:' + str(json.loads((root / 'server.json').read_text())['port'])
        def stats():
            return json.load(urllib.request.urlopen(base + '/stats', timeout=5))
        for lang in ['de', 'en']:
            target = root / lang
            target.mkdir()
            for name in ['home', 'recordings', 'history', 'buffers']:
                (target / name).mkdir()
            sentinel = target / 'recordings/permanent-sentinel.mp3'
            sentinel.write_bytes(b'Existing recording')
            app = root / 'TimeshiftTransportProbe.app'
            launcher = subprocess.Popen(['open', '-n', '-W', str(app),
                '--env', 'CFFIXED_USER_HOME=' + str(target / 'home'),
                '--env', 'MUCKE_TRANSPORT_INTEGRATION=1',
                '--env', 'MUCKE_TRANSPORT_QUICK=' + ('1' if lang == 'en' else '0'),
                '--args', str(target), base + '/aac',
                '-AppleLanguages', '(' + lang + ')', '-AppleLocale', 'de_DE' if lang == 'de' else 'en_US',
                '-volume', '0', '-recordStreams', 'NO'])
            helper.wait(lambda: (target / 'app.pid').exists(), target=target)
            pid = int((target / 'app.pid').read_text())
            (root / 'app.owned.json').write_text(json.dumps(dict(pid=pid, expected=str(app / 'Contents/MacOS/TimeshiftTransportProbe'))))
            def command(action, *args):
                return subprocess.check_output([str(ax), action, str(pid), *args], text=True, timeout=10)
            def mark(name, seconds=45):
                helper.wait(lambda: (target / (name + '.txt')).exists(), seconds, target)
            mark('integration-pause-ready')
            command('press', 'timeshift-pause')
            mark('integration-record-off-ready')
            command('press', 'mini-recording-toggle')
            mark('integration-record-on-ready')
            command('press', 'mini-recording-toggle')
            mark('integration-timer-ready')
            command('press', 'sleep-timer-open')
            command('press', 'sleep-timer-duration')
            command('press-title', 'Eigene Dauer' if lang == 'de' else 'Custom duration')
            command('set-field', 'sleep-timer-custom', '1')
            dump = command('dump')
            (target / 'paused-timer-ax.json').write_text(dump)
            command('press', 'sleep-timer-start')
            mark('integration-wake-live-ready', 110)
            subprocess.run([str(root / 'media-key'), str(pid)], check=True, timeout=5)
            mark('integration-passed', 700 if lang == 'de' else 400)
            assert launcher.wait(timeout=15) == 0
            helper.wait(lambda: not stats()['active'])
            assert sentinel.read_bytes() == b'Existing recording'
            assert not [p for p in (target / 'buffers').iterdir() if p.is_dir()]
            (target / 'connections.json').write_text(json.dumps(stats(), indent=2))
            (root / 'app.owned.json').unlink()
        (root / 'result.json').write_text(json.dumps(dict(passed=True, languages=['de', 'en'], connectionsAfterQuit=0)))
        verify(root)
    finally:
        helper.cleanup(root)
        if server.poll() is None:
            server.terminate()
        server.wait(timeout=10)


def verify(root):
    results = []
    for lang in ['de', 'en']:
        target = root / lang
        observations = json.loads((target / 'observations.json').read_text())
        by_stage = {entry['stage']: entry for entry in observations}
        assert by_stage['record-off-paused']['paused']
        for stage in ['record-off-paused', 'reconnected-held']:
            assert by_stage[stage]['systemState'] == 2
        paused_title = by_stage['record-off-paused']['title'].split(' - ', 1)[-1]
        assert by_stage['record-off-paused']['systemTitle'].endswith(' — ' + paused_title)
        assert by_stage['heaac-resume']['systemState'] == 1
        assert by_stage['timer-expired']['playing'] is False
        assert by_stage['wake-held']['playing'] is False
        assert by_stage['reconnected-held']['playing'] is False
        assert by_stage['hls-path']['recording'] == by_stage['hls-mime']['recording'] == 'unsupportedFormat'
        if lang == 'de':
            assert by_stage['aac-full-pause-expired']['phase'] == 'expired'
        exports = []
        for file in sorted((target / 'exports').glob('*.m4a')):
            probe = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries', 'format=duration:stream=codec_name',
                '-of', 'json', str(file)]))
            duration = float(probe['format']['duration'])
            assert 2.8 < duration < 3.2
            subprocess.run(['ffmpeg', '-v', 'error', '-i', str(file), '-f', 'null', '-'], check=True, capture_output=True, timeout=30)
            exports.append(dict(file=file.name, duration=duration))
        assert len(exports) == 12
        effects = {}
        effect_entries = json.loads((target / 'effects.json').read_text()) if lang == 'de' else []
        for entry in effect_entries:
            decoded = subprocess.check_output(['ffmpeg', '-v', 'error', '-i', str(target / entry['file']),
                '-ac', '1', '-ar', '48000', '-f', 'f32le', '-'])
            samples = array.array('f', decoded)
            assert len(samples) > 3 * 48000
            window = samples[48000:2 * 48000]
            amplitudes = {f: 2 * abs(sum(v * complex(math.cos(-2 * math.pi * f * i / 48000),
                math.sin(-2 * math.pi * f * i / 48000)) for i, v in enumerate(window))) / len(window) for f in [125, 1000, 8000]}
            effects[(entry['codec'], entry['mode'])] = amplitudes
        for codec in (['mp3', 'aac'] if lang == 'de' else []):
            off, flat, cut = [effects[(codec, mode)] for mode in ['off', 'flat', 'cut']]
            assert all(0.98 < flat[f] / off[f] < 1.02 for f in off)
            assert 0.20 < cut[1000] / off[1000] < 0.30
            assert all(0.94 < cut[f] / off[f] < 1.06 for f in [125, 8000])
        events = json.loads((target / 'connections.json').read_text())['events']
        hls = [entry for entry in events if entry.get('capture') and entry.get('path', '').endswith('.m3u8')]
        assert not hls, 'HLS-Pfad öffnet zusätzliche ICY-Verbindung'
        manifest = [entry for entry in events if entry.get('capture') and entry.get('path') == '/manifest']
        assert len(manifest) == (1 if lang == 'de' else 2), 'HLS-MIME erzeugt Retry-Schleife'
        effect_results = {codec: {mode: {str(f): value for f, value in effects[(codec, mode)].items()}
            for mode in ['off', 'flat', 'cut']} for codec in (['mp3', 'aac'] if lang == 'de' else [])}
        results.append(dict(language=lang, stages=list(by_stage), exports=exports, equalizer=effect_results))
    (root / 'independent-check.json').write_text(json.dumps(results, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['prepare', 'serve', 'run', 'verify', 'cleanup'])
    parser.add_argument('root', type=lambda value: Path(value).expanduser().resolve())
    args = parser.parse_args()
    if args.mode == 'cleanup':
        common().cleanup(args.root)
    else:
        globals()[args.mode](args.root)
