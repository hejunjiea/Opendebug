#!/usr/bin/env python3
"""Read one ODebug response, stopping at the protocol end marker.

The 4322 daemon sends __ODEBUG_END__ after each response. Older 4321/4322
servers do not, so this client also supports a short quiet-period fallback.
"""

import argparse
import os
import socket
import sys
import time


END_MARKER = b"__ODEBUG_END__"
BANNER_MARKER = "输入 help 看命令菜单".encode("utf-8")


def read_response(host: str, port: int, timeout: float, quiet: float) -> bytes:
    token = os.environ.get("ODEBUG_WIRE_TOKEN", "")
    command = os.environ.get("ODEBUG_WIRE_COMMAND", "")
    if not token or not command:
        raise ValueError("ODEBUG_WIRE_TOKEN and ODEBUG_WIRE_COMMAND are required")

    deadline = time.monotonic() + timeout
    data = bytearray()
    sock = socket.create_connection((host, port), timeout=min(timeout, 3.0))
    sock.settimeout(min(0.2, timeout))
    try:
        sock.sendall(("AUTH %s %s\n" % (token, command)).encode("utf-8"))
        banner_end = -1
        response_started = False
        last_response_byte = 0.0

        while time.monotonic() < deadline:
            try:
                chunk = sock.recv(65536)
            except socket.timeout:
                now = time.monotonic()
                if response_started and now - last_response_byte >= quiet:
                    break
                continue
            if not chunk:
                break

            data.extend(chunk)
            marker_at = data.find(END_MARKER)
            if marker_at >= 0:
                del data[marker_at:]
                break

            if banner_end < 0:
                banner_at = data.find(BANNER_MARKER)
                if banner_at >= 0:
                    newline_at = data.find(b"\n", banner_at)
                    if newline_at >= 0:
                        banner_end = newline_at + 1
            if banner_end >= 0 and len(data) > banner_end:
                response_started = True
                last_response_byte = time.monotonic()
    finally:
        sock.close()

    marker_at = data.find(END_MARKER)
    if marker_at >= 0:
        del data[marker_at:]
    return bytes(data)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--timeout", type=float, default=20.0)
    parser.add_argument("--quiet", type=float, default=0.35)
    args = parser.parse_args()
    try:
        output = read_response(args.host, args.port, args.timeout, args.quiet)
    except Exception as error:
        print("ODebug wire error: %s" % error, file=sys.stderr)
        return 1
    sys.stdout.buffer.write(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
