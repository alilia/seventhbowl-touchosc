"""Seventh Bowl ceremony logger.

Records every OSC message from the ESP32s to a log, one JSON object per line, and passes each
message straight on to TouchOSC on this laptop. The studio (studio.seventhbowl.com/ceremony/)
draws a ceremony from the log.

    pip install python-osc
    python osc_logger.py                          asks for a note, Enter to skip
    python osc_logger.py "closed test, Dong Ding" the note given right away

While it runs, press Enter to mark a moment (type a word first to label it, e.g. "first pour").
Ctrl+C stops it.

Ports: the ESP32s broadcast to LISTEN_PORT. This script takes that port and forwards to
TouchOSC on FORWARD, so TouchOSC on this laptop must listen on 10001, not 10000.
A second laptop's TouchOSC listens on 10000 directly and needs nothing from here.

Log format 1:
    first line   {"session": {"started": ISO time, "note": ..., "format": 1, "logger": ..., "listen": ..., "forward": [...]}}
    messages     {"t": seconds since start, "addr": "/okuma/cup1", "args": [value, ...]}
    markers      {"t": ..., "addr": "/mark", "args": [number, "label"]}
"""
import argparse
import datetime
import json
import os
import re
import sys
import threading
import time

try:
    from pythonosc import dispatcher, osc_server, udp_client
except ImportError:
    sys.exit("python-osc is missing. Install it with:  pip install python-osc")

LOGGER_VERSION = "2"
LOG_FORMAT = 1
LISTEN_PORT = 10000                      # the ESP32s broadcast here
FORWARD = [("127.0.0.1", 10001)]         # TouchOSC on this laptop
HERE = os.path.dirname(os.path.abspath(__file__))
CEREMONIES = os.path.normpath(os.path.join(HERE, "..", "ceremonies"))


def folder_name(started, note):
    """2026-11-03_1902 closed test  (characters Windows can't use in names are dropped)"""
    name = started.strftime("%Y-%m-%d_%H%M")
    short = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "", note).strip().strip(".")[:40].strip()
    return name + (" " + short if short else "")


def parse_forward(values):
    out = []
    for v in values:
        host, _, port = v.rpartition(":")
        out.append((host or "127.0.0.1", int(port)))
    return out


def main():
    ap = argparse.ArgumentParser(description="Record a Seventh Bowl ceremony and pass the OSC on to TouchOSC.")
    ap.add_argument("note", nargs="*", help="a short note for this log, e.g. closed test, Dong Ding")
    ap.add_argument("--listen", type=int, default=LISTEN_PORT, help="UDP port the ESP32s send to (default %(default)s)")
    ap.add_argument("--forward", action="append", metavar="HOST:PORT",
                    help="where to pass messages on (default 127.0.0.1:10001); repeat for more")
    ap.add_argument("--out", default=CEREMONIES, help="folder for the ceremony folders (default %(default)s)")
    a = ap.parse_args()

    note = " ".join(a.note).strip()
    if not note and sys.stdin.isatty():
        note = input("Note for this log (Enter to skip): ").strip()
    forward = parse_forward(a.forward) if a.forward else FORWARD

    started = datetime.datetime.now().astimezone()
    folder = os.path.join(a.out, folder_name(started, note))
    base, n = folder, 2
    while os.path.exists(folder):
        folder = f"{base} ({n})"; n += 1
    os.makedirs(folder)
    path = os.path.join(folder, "ceremony.jsonl")
    log = open(path, "a", encoding="utf-8", buffering=1)
    lock = threading.Lock()
    t0 = time.time()
    count = 0
    marks = 0

    def write(obj):
        with lock:
            log.write(json.dumps(obj, ensure_ascii=False) + "\n")

    write({"session": {"started": started.isoformat(timespec="seconds"), "note": note, "format": LOG_FORMAT,
                       "logger": LOGGER_VERSION, "listen": a.listen, "forward": [f"{h}:{p}" for h, p in forward]}})

    clients = [udp_client.SimpleUDPClient(h, p) for h, p in forward]

    def handle(address, *args):
        nonlocal count
        for c in clients:                                     # pass on first, so TouchOSC never waits
            try:
                c.send_message(address, list(args))
            except OSError:
                pass
        write({"t": round(time.time() - t0, 3), "addr": address, "args": list(args)})
        count += 1

    d = dispatcher.Dispatcher()
    d.set_default_handler(handle)
    try:
        server = osc_server.ThreadingOSCUDPServer(("0.0.0.0", a.listen), d)
    except OSError as e:
        log.close()
        os.remove(path)
        os.rmdir(folder)
        sys.exit(f"Cannot listen on UDP {a.listen}: {e}\n"
                 f"Is TouchOSC on this laptop still set to receive on {a.listen}? Set it to {forward[0][1]}.")

    print("Seventh Bowl logger", LOGGER_VERSION)
    print(f"  listening   UDP {a.listen}, all interfaces (the ESP32 broadcast)")
    for h, p in forward:
        print(f"  forwarding  {h}:{p}" + ("   TouchOSC on this laptop: set its receive port to %d" % p if h in ("127.0.0.1", "localhost") else ""))
    print(f"  log         {path}")
    print(f"  note        {note or '(none)'}")
    print("Press Enter to mark a moment (type a word first to label it). Ctrl+C to stop.\n")

    def markers():
        nonlocal marks
        for line in sys.stdin:
            marks += 1
            label = line.strip()
            t = round(time.time() - t0, 3)
            write({"t": t, "addr": "/mark", "args": [marks, label]})
            m, s = divmod(int(t), 60)
            print(f"  mark {marks} at {m}:{s:02d}" + (f"  {label}" if label else ""))

    threading.Thread(target=markers, daemon=True).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        log.close()
        m, s = divmod(int(time.time() - t0), 60)
        print(f"\nStopped after {m}:{s:02d}. {count} messages, {marks} marks.\nSaved to {path}")


if __name__ == "__main__":
    main()
