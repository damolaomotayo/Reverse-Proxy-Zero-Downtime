import json
import os
import sys
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(ROOT, "app"))
import app as appmod  # noqa: E402

OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class AppTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), appmod.Handler)
        cls.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        self._saved = dict(appmod.CFG)
        appmod.CFG.update(version="v7", slot="green", fault="none", error_rate=0.3)

    def tearDown(self):
        appmod.CFG.clear()
        appmod.CFG.update(self._saved)

    def get(self, path, method="GET"):
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", method=method)
        try:
            with OPENER.open(req, timeout=3) as resp:
                return resp.status, resp.headers, resp.read()
        except urllib.error.HTTPError as err:
            return err.code, err.headers, err.read()

    def test_version_endpoint_and_headers(self):
        status, headers, body = self.get("/api/version")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["version"], "v7")
        self.assertEqual(headers["X-App-Version"], "v7")
        self.assertEqual(headers["X-App-Slot"], "green")

    def test_home_page_shows_version(self):
        status, _, body = self.get("/")
        self.assertEqual(status, 200)
        self.assertIn(b"v7", body)

    def test_healthz_ok(self):
        status, _, body = self.get("/healthz")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["status"], "ok")

    def test_head_request_has_headers_and_no_body(self):
        status, headers, body = self.get("/api/version", method="HEAD")
        self.assertEqual(status, 200)
        self.assertEqual(headers["X-App-Version"], "v7")
        self.assertEqual(body, b"")

    def test_unknown_path_is_404(self):
        self.assertEqual(self.get("/nope")[0], 404)

    def test_fault_health_breaks_only_healthz(self):
        appmod.CFG["fault"] = "health"
        self.assertEqual(self.get("/healthz")[0], 500)
        self.assertEqual(self.get("/api/version")[0], 200)

    def test_fault_errors_keeps_healthz_green_but_fails_requests(self):
        appmod.CFG.update(fault="errors", error_rate=1.0)
        self.assertEqual(self.get("/healthz")[0], 200)
        status, headers, _ = self.get("/api/version")
        self.assertEqual(status, 500)
        self.assertEqual(headers["X-App-Version"], "v7")   # failures stay attributable to a version

    def test_color_is_stable_per_version(self):
        self.assertEqual(appmod.color_for("v1"), appmod.color_for("v1"))
        self.assertNotEqual(appmod.color_for("v1"), appmod.color_for("v2"))


if __name__ == "__main__":
    unittest.main()
