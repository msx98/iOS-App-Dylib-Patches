import socket
import sys
import os
import glob
import struct

def send_data(conn, data):
    # Pack size as a 4-byte unsigned integer (Little Endian)
    conn.sendall(struct.pack('!I', len(data)))
    conn.sendall(data)

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(('0.0.0.0', 8887))
    s.listen(1)
    print("[*] Waiting for iPhone connection...")

    conn, addr = s.accept()
    with conn:
        print(f"[*] Connected by {addr}")
        conn.sendall(b"READY\n")

        # 1. Get list of dylibs
        dylib_files = glob.glob("dylibs/*.dylib")
        
        # 2. Send the count of dylibs first
        conn.sendall(struct.pack('!I', len(dylib_files)))

        for file_path in dylib_files:
            name = os.path.basename(file_path).encode()
            with open(file_path, 'rb') as f:
                data = f.read()
            
            print(f"[*] Sending {os.path.basename(file_path)} ({len(data)} bytes)...")
            # Send name (size + data)
            conn.sendall(struct.pack('<I', len(name)))
            conn.sendall(name)
            conn.sendall(struct.pack('!I', len(data)))
            # Send file (size + data)
            conn.sendall(data)

        print("[*] All dylibs sent. Keeping connection alive. Press Ctrl+C to close (will kill app).")
        try:
            while True:
                # Keep the connection open. If the script is killed, 
                # the socket closes and the iPhone app will exit.
                data = conn.recv(1024)
                if not data: break 
                print(f"iPhone: {data.decode(errors='ignore').strip()}")
        except KeyboardInterrupt:
            pass
