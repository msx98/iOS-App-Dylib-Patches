#!/usr/bin/env python3

from typing import Tuple, Dict
import socket
import select
import sys
import os
import glob
from collections import defaultdict
from io import BytesIO
from threading import Thread, Lock, Event
from pathlib import Path
import struct

DYLIB_PORT = 8887
LOGS_PORT = 8889

files = list(map(Path, sys.argv[1:]))
if missing := [x for x in files if not x.exists()]:
    sys.stderr.write(f"ERROR: Some files are missing: {missing}\n")
    sys.stderr.flush()
    exit(1)
m_files = []
for file in files:
    if file.suffix != ".m":
        continue
    m_files.append(file)

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    s.connect(('1.1.1.1', 53))
    ip_addr = s.getsockname()[0]
    s.close()
except Exception:
    ip_addr = ""


# buffer example
b = BytesIO()
b.write(b"Hello, World!\n")


class LogThread:
    def __init__(self):
        self._running = True
        self._buffer_map: Dict[Tuple[str, int], BytesIO] = defaultdict(BytesIO)
        self._thread = Thread(target=self._loop)
        self._lock = Lock()
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._min_recv_timeout = 0.1
        self._max_recv_timeout = 1
        self._recv_timeout_step = 0.1
        self._recv_timeout = self._min_recv_timeout
    
    def start(self):
        self._thread.start()
    
    def remove(self, addr):
        with self._lock:
            if buf := self._buffer_map.pop(addr, None):
                buf.seek(0)
                remaining = buf.read()
                if remaining:
                    sys.stdout.write(remaining.decode(errors='replace'))
                    if not remaining.endswith(b'\n'):
                        sys.stdout.write('\n')
                    sys.stdout.flush()

    def _loop(self):
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind(('0.0.0.0', LOGS_PORT))
        self._sock.settimeout(self._recv_timeout)
        print(f"[*] LogThread started, listening for logs on port udp://{ip_addr}:{LOGS_PORT}...", flush=True)
        while self._running:
            try:
                data, addr = self._sock.recvfrom(65535)
                if data:
                    with self._lock:
                        buf = self._buffer_map[addr]
                        buf.write(data)
                        buf.seek(0)
                        content = buf.read()
                        last_nl = content.rfind(b'\n')
                        if last_nl >= 0:
                            sys.stdout.write(content[:last_nl + 1].decode(errors='replace'))
                            sys.stdout.flush()
                            remainder = content[last_nl + 1:]
                            buf.seek(0)
                            buf.truncate(0)
                            buf.write(remainder)
                    if self._running:
                        self._recv_timeout = max(self._min_recv_timeout, self._recv_timeout - self._recv_timeout_step)
                        self._sock.settimeout(self._recv_timeout)
            except socket.timeout:
                self._recv_timeout = min(self._max_recv_timeout, self._recv_timeout + self._recv_timeout_step)
                self._sock.settimeout(self._recv_timeout)
            except Exception:
                break

    def stop(self):
        print("[*] Stopping LogThread...", flush=True)
        self._running = False
        with self._lock:
            for buf in self._buffer_map.values():
                buf.seek(0)
                remaining = buf.read()
                if remaining:
                    sys.stdout.write(remaining.decode(errors='replace'))
                    if not remaining.endswith(b'\n'):
                        sys.stdout.write('\n')
            self._buffer_map.clear()
            sys.stdout.flush()
        print("[*] LogThread Joining...", flush=True)
        for addr in list(self._buffer_map.keys()):
            self._sock.sendto(b'BYE', addr)
        self._sock.close()
        self._thread.join()
        print("[*] LogThread stopped.", flush=True)



def send_data(conn, data):
    # Pack size as a 4-byte unsigned integer (Little Endian)
    conn.sendall(struct.pack('!I', len(data)))
    conn.sendall(data)


with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
    t = LogThread()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(('0.0.0.0', DYLIB_PORT))
    s.listen(8)
    t.start()

    print(f"[*] DYLIB Waiting for iPhone connections on tcp://{ip_addr}:{DYLIB_PORT}...")
    conns = []

    try:
        while True:
            conn, addr = s.accept()
            conns.append(conn)
            print(f"[*] Connected by {addr}")
            conn.sendall(b"READY\n")
            
            # 2. Send the count of dylibs first
            conn.sendall(struct.pack('!I', len(m_files)))

            for m_file in m_files:
                dylib_file = Path("build") / m_file.with_suffix('.dylib').name
                m_file = Path(m_file.resolve())
                # If doesnt exist or older than .m
                if (not dylib_file.exists()) or (dylib_file.stat().st_mtime < m_file.stat().st_mtime):
                    print(f"[*] Building {dylib_file} from {m_file}...")
                    os.system(f"bash scripts/compile {m_file}")
                print(f"[*] Preparing to send {dylib_file}...")
                name = os.path.basename(dylib_file).encode()
                with open(dylib_file, 'rb') as f:
                    data = f.read()
                print(f"[*] Sending {os.path.basename(dylib_file)} ({len(data)} bytes)...")
                # Send name (size + data)
                conn.sendall(struct.pack('<I', len(name)))
                conn.sendall(name)
                conn.sendall(struct.pack('!I', len(data)))
                # Send file (size + data)
                conn.sendall(data)

            print("[*] All dylibs sent. Keeping connection alive until you Ctrl+C.")
    except KeyboardInterrupt:
        print("[*] KeyboardInterrupt received, shutting down...")
        for conn in conns:
            try:
                conn.sendall(b"BYE\n")
                conn.close()
            except Exception:
                pass
    finally:
        t.stop()