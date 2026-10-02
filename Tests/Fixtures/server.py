# Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
# SPDX-License-Identifier: BSD-3-Clause

"""Loopback HTTP/1.1 fixture for the optional Windows integration suite."""
import argparse
import gzip
import http.server
import socket
import ssl
import threading
import time
import zlib

closed = 0
upload_progress = set()
lock = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        super().setup()
        self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    def handle(self):
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass

    def log_message(self, *_):
        pass

    def reply(self, data=b"", status=200, length=None, fields=()):
        self.send_response(status)
        self.send_header("Content-Length",
                         str(len(data) if length is None else length))
        self.send_header("X-Port", str(self.client_address[1]))
        self.send_header("X-Path", self.path)
        self.send_header("X-Method", self.command)
        self.send_header("X-Repeated", "one")
        self.send_header("X-Repeated", "two")
        self.send_header("X-Bytes", "caf\xe9")
        if status == 302:
            self.send_header("Location", "/echo")
        for name, value in fields:
            self.send_header(name, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)
            self.wfile.flush()

    def do_HEAD(self):
        self.reply(length=42)

    def do_GET(self):
        global closed
        try:
            if self.path.startswith("/upload-progress/"):
                with lock:
                    data = b"ready" if self.path in upload_progress else b"waiting"
                self.reply(data)
            elif self.path.startswith("/benchmark/"):
                mode = self.path.rsplit("/", 1)[1]
                count, size = {"small": (0, 0), "many": (24, 64),
                               "large": (12, 1024)}[mode]
                self.reply(fields=tuple((f"X-Bench-{i}", "x" * size)
                                        for i in range(count)))
            elif self.path == "/closed":
                with lock:
                    data = str(closed).encode()
                self.reply(data)
            elif self.path == "/headers":
                self.reply(self.headers.get("X-Value", "").encode("latin-1"))
            elif self.path == "/auth":
                authorization = self.headers.get("Authorization")
                if authorization:
                    self.reply(authorization.encode("latin-1"))
                else:
                    self.reply(status=401, fields=(
                        ("WWW-Authenticate", "Negotiate"),
                        ("WWW-Authenticate", "NTLM"),
                    ))
            elif self.path.startswith("/compressed/"):
                _, _, encoding, mode = self.path.split("/")
                data = bytes(range(256)) * 768 + b"\x00\x01\x02"
                compressed = (gzip.compress(data) if encoding == "gzip"
                              else zlib.compress(data))
                fields = (("Content-Encoding", encoding),)
                if mode == "known":
                    self.reply(compressed, fields=fields)
                else:
                    self.send_response(200)
                    self.send_header("Content-Encoding", encoding)
                    self.send_header("Transfer-Encoding", "chunked")
                    self.end_headers()
                    for offset in range(0, len(compressed), 97):
                        chunk = compressed[offset : offset + 97]
                        self.wfile.write(f"{len(chunk):x}\r\n".encode("ascii"))
                        self.wfile.write(chunk + b"\r\n")
                    self.wfile.write(b"0\r\n\r\n")
                    self.wfile.flush()
            elif self.path == "/compressed-json":
                data = '{"message":"Hello, Zoë / 東京!"}'.encode("utf-8")
                self.reply(gzip.compress(data), fields=(
                    ("Content-Encoding", "gzip"),
                    ("Content-Type", "application/json"),
                    ("X-Accept-Encoding", self.headers.get("Accept-Encoding", "")),
                ))
            elif self.path == "/compressed-invalid":
                self.reply(b"not a gzip stream", fields=(
                    ("Content-Encoding", "gzip"),
                ))
            elif self.path == "/compressed-truncated":
                data = gzip.compress(b"x" * 65536)
                self.reply(data[:len(data) // 2], length=len(data), fields=(
                    ("Content-Encoding", "gzip"),
                ))
                self.close_connection = True
            elif self.path == "/compressed-stream":
                self.send_response(200)
                self.send_header("Content-Encoding", "gzip")
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                compressor = zlib.compressobj(wbits=16 + zlib.MAX_WBITS)
                for _ in range(4):
                    chunk = compressor.compress(b"x" * 8192)
                    chunk += compressor.flush(zlib.Z_SYNC_FLUSH)
                    self.wfile.write(f"{len(chunk):x}\r\n".encode("ascii"))
                    self.wfile.write(chunk + b"\r\n")
                    self.wfile.flush()
                    time.sleep(0.5)
                chunk = compressor.flush()
                self.wfile.write(f"{len(chunk):x}\r\n".encode("ascii"))
                self.wfile.write(chunk + b"\r\n0\r\n\r\n")
                self.wfile.flush()
            elif self.path == "/encoded-unknown":
                self.reply(b"opaque", fields=(("Content-Encoding", "custom"),))
            elif self.path == "/race":
                time.sleep(0.005)
                self.reply(b"hello")
            elif self.path == "/zero":
                self.reply()
            elif self.path in ("/download", "/chunked"):
                data = bytes(range(256)) * 768 + b"\x00\x01\x02"
                if self.path == "/download":
                    self.reply(data)
                else:
                    self.send_response(200)
                    self.send_header("Transfer-Encoding", "chunked")
                    self.end_headers()
                    for offset in range(0, len(data), 4093):
                        chunk = data[offset : offset + 4093]
                        self.wfile.write(f"{len(chunk):x}\r\n".encode("ascii"))
                        self.wfile.write(chunk + b"\r\n")
                    self.wfile.write(b"0\r\n\r\n")
                    self.wfile.flush()
            elif self.path == "/abandon":
                self.reply(b"x" * 8192, length=65536)
                self.connection.settimeout(2)
                try:
                    shutdown = self.connection.recv(1) == b""
                except (ConnectionResetError, ConnectionAbortedError):
                    shutdown = True
                if shutdown:
                    with lock:
                        closed += 1
                self.close_connection = True
            elif self.path == "/delay":
                time.sleep(3)
                self.reply(b"late")
            elif self.path == "/stall":
                self.reply(length=65536)
                time.sleep(3)
                self.wfile.write(b"x" * 65536)
            elif self.path == "/stream":
                self.reply(length=32768)
                for _ in range(4):
                    self.wfile.write(b"x" * 8192)
                    self.wfile.flush()
                    time.sleep(0.5)
            elif self.path == "/fragment":
                self.reply(b"x", length=2)
                time.sleep(1.5)
                self.wfile.write(b"y")
                self.wfile.flush()
            elif self.path == "/truncated":
                self.reply(b"abc", length=10)
                self.close_connection = True
            elif self.path == "/redirect":
                self.reply(status=302)
            elif self.path == "/empty":
                self.reply(status=204)
            else:
                self.reply(b"hello")
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            self.close_connection = True

    def do_POST(self):
        try:
            if self.path == "/disconnect":
                self.close_connection = True
                return
            if self.path == "/reject":
                self.reply(b"rejected", status=413,
                           fields=(("Connection", "close"),))
                self.close_connection = True
                return
            if self.path == "/blocked":
                time.sleep(3)
            if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
                data = bytearray()
                while True:
                    length = int(self.rfile.readline().strip(), 16)
                    if length == 0:
                        assert self.rfile.readline() == b"\r\n"
                        break
                    data.extend(self.rfile.read(length))
                    assert self.rfile.read(2) == b"\r\n"
                    if self.path.startswith("/upload-progress/"):
                        with lock:
                            upload_progress.add(self.path)
            else:
                length = int(self.headers.get("Content-Length", "0"))
                if self.path.startswith("/upload-progress/") and length:
                    data = self.rfile.read(1)
                    with lock:
                        upload_progress.add(self.path)
                    data += self.rfile.read(length - 1)
                else:
                    data = self.rfile.read(length)
            if self.path == "/benchmark-upload":
                self.reply(fields=(("X-Upload-Length", str(len(data))),))
            else:
                self.reply(data)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            self.close_connection = True


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18841)
    parser.add_argument("--tls-port", type=int)
    parser.add_argument("--certificate")
    parser.add_argument("--key")
    args = parser.parse_args()
    http.server.ThreadingHTTPServer.request_queue_size = 128
    server = http.server.ThreadingHTTPServer((args.host, args.port), Handler)
    if args.tls_port:
        tls = http.server.ThreadingHTTPServer(
            (args.host, args.tls_port), Handler
        )
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(args.certificate, args.key)
        tls.socket = context.wrap_socket(tls.socket, server_side=True)
        threading.Thread(target=tls.serve_forever, daemon=True).start()
    print(f"Fixture ready at http://{args.host}:{args.port}", flush=True)
    server.serve_forever()
