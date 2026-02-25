import socket
import sys

# Usage: python3 bridge.py build/MicSpoof.dylib
file_path = sys.argv[1]

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(('0.0.0.0', 8887))
    s.listen(1)
    print("[*] Waiting for iPhone connection...")
    
    conn, addr = s.accept()
    with conn:
        print(f"[*] Connected by {addr}")
        
        # Read the initial "Connected" message from iPhone
        ready_msg = conn.recv(1024).decode(errors='ignore')
        print(f"iPhone: {ready_msg.strip()}")

        # Send the dylib
        with open(file_path, 'rb') as f:
            print("[*] Sending dylib...")
            conn.sendall(f.read())
        
        # Shutdown only the sending side so we can still receive the status
        conn.shutdown(socket.SHUT_WR)
        
        # Wait for the final status (LOAD SUCCESS or ERROR)
        final_status = conn.recv(1024).decode(errors='ignore')
        print(f"iPhone Result: {final_status.strip()}")
    conn, addr = s.accept()
    with conn:
        while True:
            nb = conn.recv(8); b = conn.recv(nb); print(b.decode("UTF-8"))
