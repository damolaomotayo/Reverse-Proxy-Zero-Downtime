import os
import sys
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(ROOT, "app"))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import app as appmod  # noqa: E402
import probe  # noqa: E402


class ProbeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), appmod.Handler)
        cls.url = f"http://127.0.0.1:{cls.server.server_address[1]}/api/version"
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        self._saved = dict(appmod.CFG)
        appmod.CFG.update(version="v9", slot="blue", fault="none", error_rate=0.3)

    def tearDown(self):
        appmod.CFG.clear()
        appmod.CFG.update(self._saved)

    def test_counts_requests_by_version(self):
        result = probe.run(self.url, duration=1.0, rps=40)
        self.assertGreater(result["total"], 20)
        self.assertEqual(result["errors"], 0)
        self.assertEqual(list(result["by_version"]), ["v9"])

    def test_failures_are_attributed_to_the_version_that_failed(self):
        appmod.CFG.update(fault="errors", error_rate=1.0)
        result = probe.run(self.url, duration=0.8, rps=40)
        self.assertGreater(result["errors"], 10)
        self.assertEqual(result["errors"], result["total"])
        self.assertEqual(result["by_version"]["v9"]["ok"], 0)

    def test_unreachable_server_counts_as_errors(self):
        result = probe.run("http://127.0.0.1:1/api/version", duration=0.5, rps=20, timeout=0.5)
        self.assertGreater(result["total"], 0)
        self.assertEqual(result["errors"], result["total"])
        self.assertIn("none", result["by_version"])

    def test_stop_file_ends_the_run_early(self):
        with tempfile.TemporaryDirectory() as tmp:
            stop = os.path.join(tmp, "stop")
            open(stop, "w").close()
            result = probe.run(self.url, duration=30, rps=20, stop_file=stop)
        self.assertLess(result["seconds"], 5)

    def test_report_lists_every_version(self):
        text = probe.format_report({
            "seconds": 2.0, "total": 10, "errors": 1, "error_rate_pct": 10.0,
            "by_version": {"v1": {"ok": 6, "err": 0}, "v2": {"ok": 3, "err": 1}},
        })
        self.assertIn("v1", text)
        self.assertIn("v2", text)
        self.assertIn("1 failed", text)


if __name__ == "__main__":
    unittest.main()
