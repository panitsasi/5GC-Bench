#!/usr/bin/env python3
import socket, time

BIND_IP   = "0.0.0.0"   # or use UE IP like "12.1.1.2"
BIND_PORT = 5005

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind((BIND_IP, BIND_PORT))
print(f"[UDP-SERVER] Listening on {BIND_IP}:{BIND_PORT}", flush=True)

count = 0
start = time.time()
try:
    while True:
        data, addr = sock.recvfrom(65535)
        count += 1
        if count % 100 == 0:
            dur = time.time() - start
            print(f"[UDP-SERVER] {count} packets (last from {addr}) in {dur:.2f}s", flush=True)
except KeyboardInterrupt:
    pass
finally:
    dur = time.time() - start
    print(f"[UDP-SERVER] Total {count} packets in {dur:.2f}s", flush=True)




