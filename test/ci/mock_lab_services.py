#!/usr/bin/env python3
"""Stand-ins for the lab's server :443 and validator :4435, for mocked CI runs.

    mock_lab_services.py <tls_port> <validator_port> <expected_secret> <ready_file>

- tls_port: accepts and closes connections. run_challenges.sh's
  wait_for_server_ready only checks that the port opens.
- validator_port: reads one line and replies the way validator/src/main.rs
  does, ANSI colours included: "OK — challenge solved" when the line equals
  expected_secret, otherwise "FAIL — incorrect secret".

Writes ready_file once both ports are bound. Runs until killed. Standard
library only, binds 127.0.0.1 only, so it works on ubuntu, macos and
windows runners.
"""
import socket
import sys
import threading

GREEN = "\033[0;32m"
RED = "\033[0;31m"
NC = "\033[0m"


def listen(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    s.listen(16)
    return s


def tls_loop(s):
    while True:
        c, _ = s.accept()
        c.close()


def validator_conn(c, expected):
    try:
        c.settimeout(10)
        buf = b""
        while b"\n" not in buf:
            chunk = c.recv(4096)
            if not chunk:
                break
            buf += chunk
        line = buf.split(b"\n", 1)[0].decode("utf-8", "replace").strip()
        if line == expected:
            reply = f"{GREEN}OK — challenge solved{NC}\n"
        else:
            reply = f"{RED}FAIL — incorrect secret{NC}\n"
        c.sendall(reply.encode("utf-8"))
    except OSError:
        pass
    finally:
        c.close()


def validator_loop(s, expected):
    while True:
        c, _ = s.accept()
        threading.Thread(target=validator_conn, args=(c, expected), daemon=True).start()


def main():
    tls_port, val_port, expected, ready = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]
    t, v = listen(tls_port), listen(val_port)
    threading.Thread(target=tls_loop, args=(t,), daemon=True).start()
    threading.Thread(target=validator_loop, args=(v, expected), daemon=True).start()
    with open(ready, "w") as f:
        f.write("ready\n")
    threading.Event().wait()


if __name__ == "__main__":
    main()
