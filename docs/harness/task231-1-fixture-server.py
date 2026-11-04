import http.server, base64, sys
PAGE = b"""<!doctype html><html><head><title>dialogs</title>
<style>body{margin:0} #f{position:absolute;left:10px;top:10px;width:300px;height:60px}</style></head>
<body><input type=file id=f><p style="margin-top:100px">fixture</p></body></html>"""
OK = "Basic " + base64.b64encode(b"alice:s3cret").decode()
OKQD = "Basic " + base64.b64encode(b"bob:pw2").decode()
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body, extra=()):
        self.send_response(code)
        self.send_header("Content-Type", "text/html")
        for k, v in extra: self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.path.startswith("/auth"):
            want = OKQD if self.path.startswith("/authqd") else OK
            if self.headers.get("Authorization") == want:
                self.send(200, b"<title>authed</title>ok")
            else:
                self.send(401, b"<title>denied</title>no", [("WWW-Authenticate", 'Basic realm="fixture"')])
        else:
            self.send(200, PAGE)
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
