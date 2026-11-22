#!/usr/bin/env python3

import os
import socket
import subprocess
import tempfile
import threading
import time
import unittest


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLIENT = os.path.join(ROOT, "tools", "odebug_wire_client.py")


class Server:
    def __init__(self, payload, hold=2.0):
        self.payload = payload
        self.hold = hold
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(1)
        self.port = self.sock.getsockname()[1]
        self.thread = threading.Thread(target=self.run, daemon=True)

    def run(self):
        conn, _ = self.sock.accept()
        with conn:
            conn.recv(65536)
            conn.sendall(self.payload)
            time.sleep(self.hold)
        self.sock.close()

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *args):
        self.thread.join(timeout=3)


def run_client(port, quiet):
    env = dict(os.environ)
    env["ODEBUG_WIRE_TOKEN"] = "test-token"
    env["ODEBUG_WIRE_COMMAND"] = "!sys"
    start = time.monotonic()
    result = subprocess.run(
        ["python3", CLIENT, "--host", "127.0.0.1", "--port", str(port),
         "--timeout", "2", "--quiet", str(quiet)],
        env=env, text=True, capture_output=True, check=False)
    return result, time.monotonic() - start


class WireClientTests(unittest.TestCase):
    def test_end_marker_returns_without_waiting_for_socket_close(self):
        payload = (
            "ODebug 常驻调试服务\n输入 help 看命令菜单\n结果正常\n"
            "__ODEBUG_END__\n").encode()
        with Server(payload, hold=2.0) as server:
            result, elapsed = run_client(server.port, 0.35)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("结果正常", result.stdout)
        self.assertNotIn("__ODEBUG_END__", result.stdout)
        self.assertLess(elapsed, 0.8)

    def test_old_server_uses_quiet_fallback(self):
        payload = (
            "ODebug 常驻调试服务\n输入 help 看命令菜单\n旧服务结果\n").encode()
        with Server(payload, hold=2.0) as server:
            result, elapsed = run_client(server.port, 0.2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("旧服务结果", result.stdout)
        self.assertLess(elapsed, 1.0)


if __name__ == "__main__":
    unittest.main()
