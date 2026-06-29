#!/usr/bin/env python3
# Minimal MQTT 3.1.1 publisher (pure socket). Publishes an EMPTY RETAINED payload
# to each topic given as argv -> clears a retained message (e.g. removes an HA
# discovery config so HA deletes the entity).
import socket, sys, struct

HOST = "192.168.4.11"; PORT = 1883
topics = sys.argv[1:]
if not topics:
    print("usage: mqtt_pub.py <topic> [<topic> ...]  (publishes empty retained payload)"); sys.exit(2)

def enc_len(n):
    out = b""
    while True:
        d = n % 128; n //= 128
        if n > 0: d |= 0x80
        out += bytes([d])
        if n == 0: break
    return out

def enc_str(s):
    b = s.encode(); return struct.pack("!H", len(b)) + b

s = socket.create_connection((HOST, PORT), timeout=5)
vh = enc_str("MQTT") + bytes([0x04, 0x02]) + struct.pack("!H", 30)
pkt = vh + enc_str("ebus-claude-pub")
s.sendall(bytes([0x10]) + enc_len(len(pkt)) + pkt)
s.recv(4)  # CONNACK

for t in topics:
    # PUBLISH, retain=1 (0x31), QoS0, empty payload
    body = enc_str(t)  # topic, then empty payload (nothing)
    s.sendall(bytes([0x31]) + enc_len(len(body)) + body)
    print(f"cleared retained: {t}")

# DISCONNECT
s.sendall(bytes([0xE0, 0x00]))
s.close()
