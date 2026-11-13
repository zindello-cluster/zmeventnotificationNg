"""A pretend phone, for the smoke test: it connects to the event server as the app does (a
WebSocket over TLS on port 9000), signs in as a ZoneMinder user, and registers a push token.
Standard library only: it runs with the ZoneMinder image's own Python.

  python3 - <user> <password> <token> < alert-rules/tests/phone.py
"""
import base64
import json
import os
import socket
import ssl
import struct
import sys

user, password, token = sys.argv[1:4]

context = ssl.create_default_context()
context.check_hostname = False
context.verify_mode = ssl.CERT_NONE  # the image's own self-signed certificate
sock = context.wrap_socket(socket.create_connection(("127.0.0.1", 9000), timeout=20))

key = base64.b64encode(os.urandom(16)).decode()
sock.sendall(
    (
        "GET / HTTP/1.1\r\nHost: 127.0.0.1:9000\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
    ).encode()
)
reply = b""
while b"\r\n\r\n" not in reply:
    chunk = sock.recv(4096)
    if not chunk:
        sys.exit("the event server closed the connection before the handshake")
    reply += chunk
head, rest = reply.split(b"\r\n\r\n", 1)
if b" 101 " not in head.split(b"\r\n")[0]:
    sys.exit(f"no WebSocket handshake: {head.splitlines()[0]!r}")


def send(message):
    data = json.dumps(message).encode()
    mask = os.urandom(4)
    length = len(data)
    if length < 126:
        header = struct.pack("!BB", 0x81, 0x80 | length)
    else:
        header = struct.pack("!BBH", 0x81, 0x80 | 126, length)
    sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))


def need(count):
    global rest
    while len(rest) < count:
        chunk = sock.recv(4096)
        if not chunk:
            sys.exit("the event server closed the connection")
        rest += chunk
    out, rest = rest[:count], rest[count:]
    return out


def receive():
    """The next text message, as JSON."""
    while True:
        first, second = need(2)
        length = second & 0x7F
        if length == 126:
            (length,) = struct.unpack("!H", need(2))
        elif length == 127:
            (length,) = struct.unpack("!Q", need(8))
        data = need(length)
        if first & 0x0F == 1:
            return json.loads(data)
        if first & 0x0F == 8:
            sys.exit("the event server closed the connection")


send({"event": "auth", "data": {"user": user, "password": password, "appversion": "0.0.0-smoke"}})
answer = receive()
if answer.get("event") != "auth" or answer.get("status") != "Success":
    sys.exit(f"the sign-in was refused: {answer}")
print(f"signed in as {user}")

send(
    {
        "event": "push",
        "data": {"type": "token", "token": token, "platform": "ios", "monlist": "1", "intlist": "0", "state": "enabled"},
    }
)
# The event server answers nothing to a registration; a version request it does answer shows the
# registration before it was read.
send({"event": "control", "data": {"type": "version"}})
answer = receive()
if answer.get("status") != "Success":
    sys.exit(f"after registering: {answer}")
print("registered its token")
sock.close()
