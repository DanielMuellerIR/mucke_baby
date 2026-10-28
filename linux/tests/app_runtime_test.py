#!/usr/bin/env python3
"""Prüft die echte App mit lokalem ICY, privatem Pulse-Server, IPC und MPRIS."""
import contextlib
import hashlib
import http.server
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import threading
import time


def wait_for(predicate, timeout=15):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            last = predicate()
            if last:
                return last
        except (FileNotFoundError, json.JSONDecodeError, ConnectionError, subprocess.CalledProcessError):
            pass
        time.sleep(.05)
    raise AssertionError('Zeitlimit bei Laufzeitprüfung; letzter Wert: ' + repr(last))


def stop_owned(process):
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=4)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=4)


def metrics(pid, seconds=4):
    def ticks():
        fields = Path('/proc', str(pid), 'stat').read_text().split(') ', 1)[1].split()
        return int(fields[11]) + int(fields[12])
    def thread_ticks():
        result = {}
        for task in Path("/proc", str(pid), "task").iterdir():
            try:
                fields = (task / "stat").read_text().split(") ", 1)[1].split()
                result[task.name] = ((task / "comm").read_text().strip(), int(fields[11])+int(fields[12]))
            except FileNotFoundError:
                pass
        return result
    threads_before = thread_ticks()
    initial = ticks()
    started = time.monotonic()
    time.sleep(seconds)
    cpu = 100 * (ticks() - initial) / os.sysconf('SC_CLK_TCK') / (time.monotonic() - started)
    values = {}
    for line in Path('/proc', str(pid), 'smaps_rollup').read_text().splitlines():
        if line.startswith(('Rss:', 'Pss:')):
            key, value, _unit = line.split()
            values[key[:-1].lower() + 'KiB'] = int(value)
    threads_after = thread_ticks()
    threads = []
    for key, (name, total) in threads_after.items():
        if key in threads_before:
            percent = 100*(total-threads_before[key][1])/os.sysconf('SC_CLK_TCK')/seconds
            if percent >= .1: threads.append({'name':name,'cpuPercentOfOneCore':round(percent,2)})
    threads.sort(key=lambda item:item['cpuPercentOfOneCore'],reverse=True)
    return dict(values, cpuPercentOfOneCore=round(cpu, 2), seconds=seconds, threads=threads[:6])


def main():
    if len(sys.argv) != 2:
        raise SystemExit('Aufruf: app_runtime_test.py /path/to/mucke-baby')
    binary = str(Path(sys.argv[1]).resolve(strict=True))
    results = {'platform': sys.platform, 'binarySha256': hashlib.sha256(Path(binary).read_bytes()).hexdigest(), 'tests': [], 'gui': os.environ.get('MUCKE_RUNTIME_GUI') == '1'}
    with tempfile.TemporaryDirectory(prefix='mucke-app-runtime-') as temporary:
        root = Path(temporary)
        runtime = root / 'runtime'
        runtime.mkdir(mode=0o700)
        tone = root / 'tone.mp3'
        if os.environ.get('MUCKE_RUNTIME_TONE'):
            shutil.copyfile(os.environ['MUCKE_RUNTIME_TONE'], tone)
        else:
            subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-n', '-f', 'lavfi', '-i',
                            'sine=frequency=440:sample_rate=48000', '-t', '24', '-c:a', 'libmp3lame', '-b:a', '128k', str(tone)], check=True)
        audio = tone.read_bytes()
        connections = []
        finished = threading.Event()
        class Stream(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass
            def do_GET(self):
                connections.append(self.path)
                self.send_response(200)
                self.send_header('Content-Type', 'audio/mpeg')
                self.send_header('icy-metaint', '4096')
                self.send_header('Connection', 'close')
                self.end_headers()
                if self.path == '/blocked':
                    finished.wait(20)
                    return
                offset = 0
                try:
                    while not finished.is_set():
                        body = bytes(audio[(offset+i) % len(audio)] for i in range(4096))
                        title = b"StreamTitle='Fixture - Track A';" if offset < 16000 * 12 else b"StreamTitle='Fixture - Track B';"
                        length = (len(title) + 15) // 16
                        self.wfile.write(body + bytes([length]) + title.ljust(length * 16, b'\0'))
                        self.wfile.flush()
                        offset += 4096
                        finished.wait(4096 / 16000)
                except (BrokenPipeError, ConnectionResetError):
                    pass
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Stream)
        server.daemon_threads = True
        server_thread = threading.Thread(target=server.serve_forever, daemon=True)
        server_thread.start()
        external_pulse = os.environ.get('MUCKE_RUNTIME_EXTERNAL_PULSE') == '1'
        server_address = os.environ['PULSE_SERVER'] if external_pulse else 'unix:' + str(runtime / 'native')
        environment = dict(os.environ, QT_QPA_PLATFORM='offscreen', XDG_RUNTIME_DIR=str(runtime), PULSE_SERVER=server_address, GIO_USE_VFS='local')
        results['audioBackend'] = 'external-isolated-sink' if external_pulse else 'private-pulseaudio'
        pulse_log = (root / 'pulse.log').open('wb')
        pulse = None
        if not external_pulse:
            pulse = subprocess.Popen(['pulseaudio', '-n', '--daemonize=no', '--exit-idle-time=-1',
                    '--load=module-native-protocol-unix socket=' + str(runtime / 'native') + ' auth-anonymous=1',
                    '--load=module-null-sink sink_name=mucke_fixture rate=48000'], env=environment,
                    stdout=pulse_log, stderr=subprocess.STDOUT)
        app = None
        app_log = (root / 'app.log').open('wb')
        try:
            if not external_pulse:
                wait_for(lambda: (runtime / 'native').is_socket(), 5)
            shared = ['--data-dir', str(root / 'data'), '--recordings-dir', str(root / 'recordings'), '--cache-dir', str(root / 'cache')]
            state_file = root / 'state.json'
            command = [binary, *shared, '--no-autoplay', '--state-file', str(state_file),
                       '--event-log', str(root / 'events.jsonl'), '--play', 'http://127.0.0.1:%d/live' % server.server_port,
                       '--recording', 'off', '--quit-after', '90000']
            if not results['gui']:
                command.append('--no-window')
            app = subprocess.Popen(command, env=environment, stdout=app_log, stderr=subprocess.STDOUT)
            def state():
                if app.poll() is not None:
                    raise AssertionError('App vorzeitig beendet: ' + (root / 'app.log').read_text(errors='replace'))
                return json.loads(state_file.read_text())
            def cli(*args):
                return subprocess.run([binary, *shared, *args], env=environment, stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, text=True, timeout=8, check=True)
            def dbus(interface, method, *args):
                return subprocess.run(['dbus-send', '--session', '--dest=org.mpris.MediaPlayer2.muckebaby',
                    '--type=method_call', '--print-reply', '/org/mpris/MediaPlayer2', interface + '.' + method, *args],
                    env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=8, check=True).stdout
            wait_for(lambda: state()['state'] == 'playing')
            results['version'] = state()['version']
            wait_for(lambda: state()['title'] == 'Fixture - Track A')
            assert not state()['recordRequested'] and not state()['recordActive']
            assert len(connections) <= 2, connections
            results['tests'].append('live-ICY-default-recording-off-two-connections')
            assert 'Playing' in dbus('org.freedesktop.DBus.Properties', 'Get', 'string:org.mpris.MediaPlayer2.Player', 'string:PlaybackStatus')
            dbus('org.freedesktop.DBus.Properties', 'Set', 'string:org.mpris.MediaPlayer2.Player', 'string:Volume', 'variant:double:0.5')
            wait_for(lambda: state()['volume'] == 50)
            reported = json.loads(cli('--status').stdout)
            assert reported['volume'] == 50
            results['tests'].append('MPRIS-properties-volume-local-IPC-status')
            time.sleep(.6)
            dbus('org.freedesktop.DBus.Properties', 'Set', 'string:org.mpris.MediaPlayer2.Player', 'string:Volume', 'variant:double:0.7')
            dbus('org.freedesktop.DBus.Properties', 'Set', 'string:org.mpris.MediaPlayer2.Player', 'string:Volume', 'variant:double:0.5')
            cli('--recording', 'on')
            cli('--recording', 'off')
            time.sleep(.7)
            current = json.loads(cli('--status').stdout)
            assert current['volume'] == 50 and not current['recordRequested'] and not current['recordActive'], current
            results['tests'].append('rapid-volume-and-recording-reversal-keeps-latest-choice')
            if results['gui']:
                wait_for(lambda: 'privat' in state()['visualizerStatus'].lower(), 8)
            results['playing'] = metrics(app.pid, 5)
            cli('--recording', 'on')
            wait_for(lambda: state()['recordActive'], 8)
            cli('--recording', 'off')
            wait_for(lambda: not state()['recordActive'])
            assert any(p.stat().st_size > 0 for p in (root / 'recordings').glob('*.mp3'))
            results['tests'].append('explicit-record-start-stop-preserves-audio')
            cli('--stop')
            wait_for(lambda: state()['state'] == 'stopped', 2)
            cli('--play', 'http://127.0.0.1:%d/blocked' % server.server_port)
            time.sleep(.2)
            stopped_at = time.monotonic()
            cli('--stop')
            wait_for(lambda: state()['state'] == 'stopped', 1)
            results['blockedStopSeconds'] = round(time.monotonic() - stopped_at, 3)
            results['tests'].append('blocked-stream-stop-under-one-second')
            results['idle'] = metrics(app.pid, 5)
            dbus('org.mpris.MediaPlayer2', 'Quit')
            assert app.wait(timeout=8) == 0
            results['tests'].append('MPRIS-quit-clean-exit')
            if os.environ.get('MUCKE_RUNTIME_PROFILE_CLEAN') == '1':
                clean_command = [binary, *shared, '--no-autoplay', '--play',
                                 'http://127.0.0.1:%d/live' % server.server_port, '--quit-after', '45000']
                if not results['gui']:
                    clean_command.append('--no-window')
                app = subprocess.Popen(clean_command, env=environment, stdout=app_log, stderr=subprocess.STDOUT)
                wait_for(lambda: json.loads(cli('--status').stdout)['state'] == 'playing')
                time.sleep(2)
                results['productionPlaying'] = metrics(app.pid, 10)
                cli('--stop')
                wait_for(lambda: json.loads(cli('--status').stdout)['state'] == 'stopped')
                results['productionIdle'] = metrics(app.pid, 10)
                dbus('org.mpris.MediaPlayer2', 'Quit')
                assert app.wait(timeout=8) == 0
                results['tests'].append('production-profile-without-diagnostic-files')
        finally:
            finished.set()
            server.shutdown()
            server.server_close()
            server_thread.join(timeout=2)
            stop_owned(app)
            stop_owned(pulse)
            app_log.close()
            pulse_log.close()
        print(json.dumps(results, indent=2))

if __name__ == '__main__':
    main()
