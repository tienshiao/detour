import http.server, sys, struct, zlib
def png(w, h, rgba):
    raw = b''.join(b'\x00' + bytes(rgba) * w for _ in range(h))
    def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')
ICON = png(16, 16, (220, 40, 40, 255)); ART = png(128, 128, (40, 40, 220, 255))
PAGE = b'<!doctype html><html><head><title>fav page</title><link rel="icon" href="/icon.png"></head><body style="background:#3a7">fixture</body></html>'
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        body, ctype = {'/icon.png': (ICON, 'image/png'), '/art.png': (ART, 'image/png')}.get(self.path.split('?')[0], (PAGE, 'text/html'))
        self.send_response(200); self.send_header('Content-Type', ctype); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
http.server.ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
