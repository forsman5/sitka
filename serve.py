import http.server
import socket
import ssl
import os
import tempfile

PORT = 3000
EXPORT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "exports", "web")


class GodotWebHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        super().end_headers()

    def log_message(self, format, *args):
        pass  # suppress per-request noise


def _generate_cert():
    """Generate a temporary self-signed cert using the cryptography package."""
    try:
        from cryptography import x509
        from cryptography.x509.oid import NameOID
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import rsa
        import datetime

        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "localhost")])
        cert = (
            x509.CertificateBuilder()
            .subject_name(name)
            .issuer_name(name)
            .public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(datetime.datetime.now(datetime.timezone.utc))
            .not_valid_after(datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=365))
            .sign(key, hashes.SHA256())
        )

        cert_file = tempfile.NamedTemporaryFile(delete=False, suffix=".pem", mode="wb")
        key_file  = tempfile.NamedTemporaryFile(delete=False, suffix=".pem", mode="wb")
        cert_file.write(cert.public_bytes(serialization.Encoding.PEM))
        key_file.write(key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.TraditionalOpenSSL,
            serialization.NoEncryption(),
        ))
        cert_file.close()
        key_file.close()
        return cert_file.name, key_file.name

    except ImportError:
        return None, None


def _get_lan_ip():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        try:
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
        except Exception:
            return "unknown"


if __name__ == "__main__":
    if not os.path.isdir(EXPORT_DIR):
        print(f"Export folder not found: {EXPORT_DIR}")
        print("Run export_and_serve.ps1 first to build the web export.")
        raise SystemExit(1)

    os.chdir(EXPORT_DIR)
    lan_ip = _get_lan_ip()

    cert_path, key_path = _generate_cert()
    use_https = cert_path is not None

    server = http.server.HTTPServer(("0.0.0.0", PORT), GodotWebHandler)

    if use_https:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(certfile=cert_path, keyfile=key_path)
        server.socket = ctx.wrap_socket(server.socket, server_side=True)
        scheme = "https"
        print("NOTE: Browser will warn about self-signed cert -- click Advanced > Proceed.\n")
    else:
        scheme = "http"
        print("NOTE: Install 'cryptography' for HTTPS/LAN support: pip install cryptography")
        print("      Without it, only localhost works (LAN devices will get a secure context error).\n")

    print(f"Serving Godot web export:")
    print(f"  Local:   {scheme}://localhost:{PORT}")
    print(f"  Network: {scheme}://{lan_ip}:{PORT}")
    print("Press Ctrl+C to stop.\n")

    try:
        server.serve_forever()
    finally:
        if use_https:
            os.unlink(cert_path)
            os.unlink(key_path)
