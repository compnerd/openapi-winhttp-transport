# Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
# SPDX-License-Identifier: BSD-3-Clause

"""Optional loopback HTTP/2 and HTTP/3 fixture (pip install aioquic h2)."""
import argparse
import asyncio
import datetime
import ipaddress
import itertools
import pathlib
import ssl
import tempfile

from aioquic.asyncio import QuicConnectionProtocol, serve
from aioquic.h3.connection import H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import StopSendingReceived, StreamReset
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID
from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import DataReceived as H2Data
from h2.events import RequestReceived, StreamEnded, WindowUpdated
from h2.events import StreamReset as H2Reset

connections = itertools.count(1)
proxied = 0


class Responses:
    def __init__(self):
        self.identifier = next(connections)
        self.requests = {}
        self.tasks = {}
        self.counts = {}

    def schedule(self, stream, coroutine):
        task = asyncio.create_task(coroutine)
        self.tasks[stream] = task
        task.add_done_callback(lambda task: self.tasks.pop(stream, None))

    def reset(self, stream):
        self.requests.pop(stream, None)
        self.counts.pop(stream, None)
        if hasattr(self, "pending"):
            self.pending.pop(stream, None)
        task = self.tasks.pop(stream, None)
        if task:
            task.cancel()

    def headers(self, stream, fields):
        path = dict(fields)[b":path"].decode().split("?")[0]
        self.requests[stream] = [path, bytearray(), False]
        self.counts[stream] = 0
        print(self.version.decode(), self.identifier, stream, path, flush=True)
        if path == "/stall":
            self.start(stream, 200, 65536)
        elif path == "/stream":
            self.schedule(stream, self.streaming(stream))

    async def streaming(self, stream):
        self.start(stream, 200, 32768)
        for index in range(4):
            self.data(stream, b"x" * 8192, index == 3)
            await asyncio.sleep(0.5)

    def received(self, stream, data):
        path, body, done = self.requests[stream]
        self.counts[stream] += len(data)
        if not done and path not in ("/stall", "/stream"):
            body.extend(data)

    def ended(self, stream):
        path, body, done = self.requests[stream]
        if done or path in ("/stall", "/stream"):
            return
        if path in ("/delay", "/parallel"):
            self.schedule(stream, self.delayed(stream))
        else:
            self.reply(stream, bytes(body) if path == "/echo" else b"hello")

    async def delayed(self, stream):
        path, body, _ = self.requests[stream]
        await asyncio.sleep(3 if path == "/delay" else 0.1)
        self.reply(stream, b"late" if path == "/delay" else bytes(body))

    def start(self, stream, status, length, ended=False):
        self.send_headers(stream, [
            (b":status", str(status).encode()),
            (b"content-length", str(length).encode()),
            (b"x-connection", str(self.identifier).encode()),
            (b"x-protocol", self.version),
            (b"x-proxy", str(proxied).encode()),
            (b"x-received", str(self.counts[stream]).encode()),
        ], ended)

    def reply(self, stream, data, status=200):
        self.requests[stream][2] = True
        self.start(stream, status, len(data), not data)
        if data:
            self.data(stream, data, True)

    def stop(self):
        for task in list(self.tasks.values()):
            task.cancel()


class HTTP2(Responses):
    version = b"h2"

    def __init__(self, writer):
        super().__init__()
        self.writer = writer
        self.connection = H2Connection(H2Configuration(
            client_side=False, header_encoding=None
        ))
        self.pending = {}
        self.connection.initiate_connection()
        self.flush()

    def flush(self):
        self.writer.write(self.connection.data_to_send())

    def send_headers(self, stream, fields, ended):
        self.connection.send_headers(stream, fields, end_stream=ended)
        self.flush()

    def data(self, stream, data, ended):
        self.pending.setdefault(stream, bytearray()).extend(data)
        self.drain(stream, ended)

    def drain(self, stream, ended=True):
        pending = self.pending[stream]
        while pending:
            count = min(len(pending), self.connection.max_outbound_frame_size,
                        self.connection.local_flow_control_window(stream))
            if count == 0:
                break
            chunk = bytes(pending[:count])
            del pending[:count]
            self.connection.send_data(stream, chunk,
                                      end_stream=ended and not pending)
        self.flush()

    async def run(self, reader):
        try:
            while data := await reader.read(65536):
                for event in self.connection.receive_data(data):
                    if isinstance(event, RequestReceived):
                        self.headers(event.stream_id, event.headers)
                    elif isinstance(event, H2Data):
                        self.received(event.stream_id, event.data)
                        self.connection.acknowledge_received_data(
                            event.flow_controlled_length, event.stream_id
                        )
                    elif isinstance(event, StreamEnded):
                        self.ended(event.stream_id)
                    elif isinstance(event, H2Reset):
                        self.reset(event.stream_id)
                    elif isinstance(event, WindowUpdated):
                        for stream in list(self.pending):
                            if self.pending[stream]:
                                self.drain(stream)
                self.flush()
        finally:
            self.stop()


class HTTP3(QuicConnectionProtocol, Responses):
    version = b"h3"

    def __init__(self, *args, **kwargs):
        QuicConnectionProtocol.__init__(self, *args, **kwargs)
        Responses.__init__(self)
        self.connection = H3Connection(self._quic)

    def send_headers(self, stream, fields, ended):
        self.connection.send_headers(stream, fields, end_stream=ended)
        self.transmit()

    def data(self, stream, data, ended):
        self.connection.send_data(stream, data, end_stream=ended)
        self.transmit()

    def quic_event_received(self, event):
        if isinstance(event, (StopSendingReceived, StreamReset)):
            self.reset(event.stream_id)
        for event in self.connection.handle_event(event):
            if isinstance(event, HeadersReceived):
                self.headers(event.stream_id, event.headers)
                if event.stream_ended:
                    self.ended(event.stream_id)
            elif isinstance(event, DataReceived):
                self.received(event.stream_id, event.data)
                if event.stream_ended:
                    self.ended(event.stream_id)

    def connection_lost(self, exception):
        self.stop()
        super().connection_lost(exception)


def certificate(directory):
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "localhost")])
    now = datetime.datetime.now(datetime.timezone.utc)
    value = (x509.CertificateBuilder()
             .subject_name(name).issuer_name(name).public_key(key.public_key())
             .serial_number(x509.random_serial_number())
             .not_valid_before(now - datetime.timedelta(minutes=1))
             .not_valid_after(now + datetime.timedelta(days=1))
             .add_extension(x509.SubjectAlternativeName([
                 x509.DNSName("localhost"),
                 x509.DNSName("winhttp.fixture.invalid"),
                 x509.IPAddress(ipaddress.ip_address("127.0.0.1")),
             ]), critical=False)
             .sign(key, hashes.SHA256()))
    root = pathlib.Path(directory)
    path = root / "certificate.pem"
    private = root / "key.pem"
    path.write_bytes(value.public_bytes(serialization.Encoding.PEM))
    private.write_bytes(key.private_bytes(serialization.Encoding.PEM,
                                          serialization.PrivateFormat.PKCS8,
                                          serialization.NoEncryption()))
    return str(path), str(private)


async def main(args):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.certificate, args.key)
    context.set_alpn_protocols(["h2", "http/1.1"])

    async def connected(reader, writer):
        try:
            tls = writer.get_extra_info("ssl_object")
            if tls.selected_alpn_protocol() == "h2":
                await HTTP2(writer).run(reader)
            else:
                await reader.readuntil(b"\r\n\r\n")
                writer.write((
                    "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n"
                    f'Alt-Svc: h3=":{args.port}"; ma=3600\r\n'
                    "Connection: close\r\n\r\nhello"
                ).encode())
                await writer.drain()
        except (ConnectionError, asyncio.IncompleteReadError):
            pass
        finally:
            writer.close()

    async def tunnel(reader, writer):
        global proxied
        upstream = None
        try:
            line = (await reader.readuntil(b"\r\n\r\n")).split(b"\r\n")[0]
            method, authority, _ = line.decode().split()
            if method != "CONNECT" or authority not in (
                f"localhost:{args.port}",
                f"winhttp.fixture.invalid:{args.port}",
            ):
                writer.write(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
                await writer.drain()
                return
            source, upstream = await asyncio.open_connection("127.0.0.1",
                                                             args.port)
            proxied += 1
            print("CONNECT", authority, flush=True)
            writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            await writer.drain()

            async def relay(source, destination):
                while data := await source.read(65536):
                    destination.write(data)
                    await destination.drain()
                destination.close()

            await asyncio.gather(relay(reader, upstream), relay(source, writer))
        except (ConnectionError, asyncio.IncompleteReadError):
            pass
        finally:
            writer.close()
            if upstream:
                upstream.close()

    proxy = await asyncio.start_server(tunnel, "127.0.0.1", args.proxy)
    configuration = QuicConfiguration(is_client=False, alpn_protocols=["h3"])
    configuration.load_cert_chain(args.certificate, args.key)
    quic = await serve("127.0.0.1", args.port, configuration=configuration,
                       create_protocol=HTTP3)
    server = await asyncio.start_server(connected, "127.0.0.1", args.port,
                                       ssl=context)
    print(f"Protocols ready at https://localhost:{args.port}", flush=True)
    try:
        async with server:
            await server.serve_forever()
    finally:
        quic.close()
        proxy.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18849)
    parser.add_argument("--proxy", type=int, default=18851)
    parser.add_argument("--certificate")
    parser.add_argument("--key")
    args = parser.parse_args()
    if bool(args.certificate) != bool(args.key):
        parser.error("--certificate and --key must be supplied together")
    with tempfile.TemporaryDirectory(prefix="winhttp-fixture-", dir=".") as root:
        if args.certificate is None:
            args.certificate, args.key = certificate(root)
        asyncio.run(main(args))
