#!/usr/bin/env python3
"""Small TLS terminator used by Nimbus integration tests."""

import argparse
import select
import signal
import socket
import ssl
import threading


def relay(client: socket.socket, backend_host: str, backend_port: int) -> None:
    try:
        with client, socket.create_connection((backend_host, backend_port)) as backend:
            sockets = (client, backend)
            while True:
                readable, _, _ = select.select(sockets, (), (), 1.0)
                for source in readable:
                    data = source.recv(64 * 1024)
                    if not data:
                        return
                    destination = backend if source is client else client
                    destination.sendall(data)
    except (ConnectionError, OSError, ssl.SSLError):
        return


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen-port", type=int, required=True)
    parser.add_argument("--backend-port", type=int, required=True)
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    args = parser.parse_args()

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.cert, args.key)
    stopping = threading.Event()

    def stop(_signum: int, _frame: object) -> None:
        stopping.set()

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    with socket.socket() as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", args.listen_port))
        listener.listen()
        listener.settimeout(0.2)
        while not stopping.is_set():
            try:
                connection, _ = listener.accept()
            except TimeoutError:
                continue
            try:
                secured = context.wrap_socket(connection, server_side=True)
            except ssl.SSLError:
                connection.close()
                continue
            threading.Thread(
                target=relay,
                args=(secured, "127.0.0.1", args.backend_port),
                daemon=True,
            ).start()


if __name__ == "__main__":
    main()
