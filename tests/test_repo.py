"""Sanity tests for the repo itself (layout, scripts, config, docs). Run from the repo root:
    python3 -m unittest discover -s tests -v
"""
import importlib.util
import os
import re
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

REQUIRED_FILES = [
    "README.md", "STEPS.md", "DEMO.md", "DIAGRAM_PROMPT.md", ".gitignore", ".gitattributes",
    ".env.example", "docker-compose.yml",
    "app/app.py", "app/Dockerfile", "tools/probe.py",
    "nginx/default.conf", "nginx/upstream/.gitkeep", "dashboard/index.html",
    "scripts/lib.sh", "scripts/setup.sh", "scripts/preflight.sh", "scripts/up.sh",
    "scripts/release.sh", "scripts/demo.sh", "scripts/smoke.sh", "scripts/destroy.sh",
]
SCRIPTS = [f for f in REQUIRED_FILES if f.endswith(".sh")]


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as fh:
        return fh.read()


class LayoutTests(unittest.TestCase):
    def test_required_files_exist(self):
        for rel in REQUIRED_FILES:
            self.assertTrue(os.path.isfile(os.path.join(ROOT, rel)), f"missing {rel}")

    def test_scripts_have_shebang(self):
        for rel in SCRIPTS:
            self.assertTrue(read(rel).startswith("#!/usr/bin/env bash"), rel)

    def test_no_crlf_line_endings(self):
        for rel in SCRIPTS + ["docker-compose.yml", "nginx/default.conf"]:
            with open(os.path.join(ROOT, rel), "rb") as fh:
                self.assertNotIn(b"\r\n", fh.read(), rel)


class ConfigTests(unittest.TestCase):
    @unittest.skipUnless(importlib.util.find_spec("yaml"), "PyYAML not installed")
    def test_compose_parses_and_has_three_services(self):
        import yaml
        data = yaml.safe_load(read("docker-compose.yml"))
        self.assertEqual(set(data["services"]), {"app-blue", "app-green", "nginx"})

    def test_only_nginx_is_public_and_apps_bind_to_localhost(self):
        ports = re.findall(r'-\s*"([^"]+)"', read("docker-compose.yml"))
        published = [p for p in ports if re.match(r"^(\d+\.\d+\.\d+\.\d+:)?\d+:\d+", p)]
        public = [p for p in published if not p.startswith("127.0.0.1:")]
        self.assertEqual(public, ["80:80"])

    def test_nginx_does_not_retry_on_http_errors(self):
        conf = read("nginx/default.conf")
        self.assertRegex(conf, r"proxy_next_upstream\s+error timeout;")
        self.assertNotRegex(conf, r"proxy_next_upstream[^;]*http_5")

    def test_preflight_does_not_use_curl_f_on_dockerhub(self):
        pre = read("scripts/preflight.sh")
        for line in pre.splitlines():
            if "registry-1.docker.io" in line and not line.lstrip().startswith("#"):
                self.assertNotRegex(line, r"curl\s+-\w*f", line)
        self.assertIn("401", pre)


class DocsTests(unittest.TestCase):
    def test_steps_covers_chmod_security_group_and_public_ip(self):
        steps = read("STEPS.md")
        self.assertIn("chmod +x scripts/*.sh tools/*.py", steps)
        self.assertRegex(steps, r"(?i)security group")
        self.assertRegex(steps, r"(?i)port range.{0,10}80|port 80")
        self.assertRegex(steps, r"(?i)port 22|`22`")
        self.assertIn("<PUBLIC-IP>", steps)
        self.assertNotRegex(steps, r"ssh .* -L ")        # no SSH tunnels needed

    def test_demo_file_is_very_brief(self):
        text = read("DEMO.md")
        self.assertLess(len(text.splitlines()), 45)
        self.assertLess(len(text.split()), 380)


if __name__ == "__main__":
    unittest.main()
