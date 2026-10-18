#!/usr/bin/env python3
"""Zeitgetakteter Loopback-Sender mit ICY und unabhängiger Verbindungszählung.

Nur synthetische Audiofixtures; kein Zugriff auf App-Daten. Zum Erzeugen:
ffmpeg -f lavfi -i "aevalsrc='0.12*sin(2*PI*if(lt(mod(t,8.064),4.032),440,880)*t)':s=48000:d=96.768"
       -ac 2 -c:a libmp3lame -b:a 128k -write_xing 0 -id3v2_version 0 tone.mp3
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import threading
import time
import uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("audio", type=Path)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--state", type=Path, required=True)
    args = parser.parse_args()
    audio = args.audio.read_bytes()
    # MPEG-1 Layer III, 48 kHz, 128 kbit/s: 384 Bytes/Frame, 42 Frames/ICY-Block.
    metaint = 384 * 42
    blocks = len(audio) // metaint
    assert blocks >= 20 and audio[:2] == b"\xff\xfb"
    lock = threading.Lock()
    active, events = {}, []
    started = time.monotonic()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def do_GET(self):
            if self.path == "/stats":
                with lock:
                    body = json.dumps({"active": active, "events": events}).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers(); self.wfile.write(body)
                return
            if self.path != "/stream.mp3":
                self.send_error(404); return
            identifier = uuid.uuid4().hex
            icy = self.headers.get("Icy-MetaData") == "1"
            with lock:
                active[identifier] = {"icy": icy, "bytes": 0}
                events.append({"event": "open", "id": identifier, "icy": icy, "at": time.monotonic()})
            try:
                self.send_response(200)
                self.send_header("Content-Type", "audio/mpeg")
                self.send_header("Connection", "close")
                if icy:
                    self.send_header("icy-metaint", str(metaint))
                self.end_headers()
                block = int((time.monotonic() - started) / 1.008)
                while True:
                    index = block % blocks
                    packet = audio[index * metaint:(index + 1) * metaint]
                    if icy:
                        hz = 440 if ((block + 1) % blocks) // 4 % 2 == 0 else 880
                        title = f"StreamTitle='Fixture - Tone {hz}';".encode()
                        length = (len(title) + 15) // 16
                        packet += bytes([length]) + title.ljust(length * 16, b"\0")
                    self.wfile.write(packet); self.wfile.flush()
                    with lock:
                        active[identifier]["bytes"] += len(packet)
                    block += 1
                    time.sleep(max(0, started + block * 1.008 - time.monotonic()))
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                self.close_connection = True
                with lock:
                    del active[identifier]
                    events.append({"event": "close", "id": identifier, "at": time.monotonic()})

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    args.state.write_text(json.dumps({"port": server.server_port, "metaint": metaint,
                                      "blockSeconds": 1.008, "sourceBytes": len(audio)}))
    server.serve_forever()


if __name__ == "__main__":
    main()
