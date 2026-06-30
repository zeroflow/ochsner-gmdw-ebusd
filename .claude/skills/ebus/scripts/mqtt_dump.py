#!/usr/bin/env python3
# Minimal read-only MQTT 3.1.1 subscriber (pure socket, no deps).
# Connects, subscribes to a topic filter, prints RETAINED messages, exits after idle.
import socket, sys, struct, time, os

# Broker defaults to the author's LAN; override via env for other setups.
HOST = os.environ.get("EBUSD_MQTT_HOST", "192.168.4.11")
PORT = int(os.environ.get("EBUSD_MQTT_PORT", "1883"))
TOPIC = sys.argv[1] if len(sys.argv) > 1 else "homeassistant/#"
IDLE = float(sys.argv[2]) if len(sys.argv) > 2 else 4.0

def enc_len(n):
    out = b""
    while True:
        d = n % 128; n //= 128
        if n > 0: d |= 0x80
        out += bytes([d])
        if n == 0: break
    return out

def enc_str(s):
    b = s.encode()
    return struct.pack("!H", len(b)) + b

s = socket.create_connection((HOST, PORT), timeout=5)

# CONNECT
vh = enc_str("MQTT") + bytes([0x04, 0x02]) + struct.pack("!H", 30)  # level4, clean session, keepalive 30
payload = enc_str("ebus-claude-ro")
pkt = vh + payload
s.sendall(bytes([0x10]) + enc_len(len(pkt)) + pkt)

# read CONNACK (4 bytes)
s.recv(4)

# SUBSCRIBE
vh = struct.pack("!H", 1)  # packet id
payload = enc_str(TOPIC) + bytes([0x00])  # QoS 0
pkt = vh + payload
s.sendall(bytes([0x82]) + enc_len(len(pkt)) + pkt)

def read_byte():
    b = s.recv(1)
    if not b: raise EOFError
    return b[0]

def read_remaining_len():
    mult = 1; val = 0
    while True:
        d = read_byte()
        val += (d & 0x7F) * mult
        if not (d & 0x80): break
        mult *= 128
    return val

def read_n(n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk: raise EOFError
        buf += chunk
    return buf

s.settimeout(IDLE)
msgs = {}
try:
    while True:
        b1 = read_byte()
        ptype = b1 >> 4
        rl = read_remaining_len()
        body = read_n(rl)
        if ptype == 3:  # PUBLISH
            retain = b1 & 0x01
            tlen = struct.unpack("!H", body[:2])[0]
            topic = body[2:2+tlen].decode("utf-8", "replace")
            payload = body[2+tlen:]  # QoS0 -> no packet id
            msgs[topic] = (retain, payload.decode("utf-8", "replace"))
        elif ptype == 9:  # SUBACK
            pass
except (socket.timeout, EOFError):
    pass
finally:
    try: s.close()
    except: pass

# Output
print(f"# topic filter: {TOPIC}  total topics received: {len(msgs)}")
SHOW = sys.argv[3] if len(sys.argv) > 3 else None  # substring -> also print payload
for t in sorted(msgs):
    retain, pl = msgs[t]
    flag = "R" if retain else " "
    if SHOW and SHOW in t:
        print(f"[{flag}] {t}\n      {pl}")
    elif not SHOW:
        print(f"[{flag}] {t}")
