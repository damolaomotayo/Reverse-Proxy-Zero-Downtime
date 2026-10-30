#!/usr/bin/env python3
"""probe.py: steady request load that records which version answered each request.

  probe.py --url http://127.0.0.1/api/version --duration 10 --rps 20 [--json]
  probe.py --url ... --duration 120 --stop-file /tmp/stop     (stops early when the file appears)
  probe.py --report result.json                               (pretty-print a saved --json result)

A request counts as an error if it does not return HTTP 200 or the connection fails.
The version comes from the X-App-Version response header (also present on 5xx from the app).
Standard library only.
"""
import argparse
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request

OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))  # never use an env proxy


def one_request(url: str, timeout: float):
    """Returns (version, ok)."""
    try:
        with OPENER.open(url, timeout=timeout) as resp:
            resp.read()
            return resp.headers.get("X-App-Version", "none"), resp.status == 200
    except urllib.error.HTTPError as err:
        return err.headers.get("X-App-Version", "none"), False
    except Exception:  # connection refused/reset, timeout, DNS ...
        return "none", False


def run(url: str, duration: float, rps: float, workers: int = 8, timeout: float = 3.0,
        stop_file: str = ""):
    by_version = {}
    lock = threading.Lock()
    started = time.monotonic()
    deadline = started + duration
    interval = workers / float(rps)

    def should_stop() -> bool:
        return time.monotonic() >= deadline or (stop_file and os.path.exists(stop_file))

    def worker(index: int) -> None:
        next_at = time.monotonic() + index * interval / workers
        while not should_stop():
            wait = next_at - time.monotonic()
            if wait > 0:
                time.sleep(min(wait, 0.05))
                continue
            next_at += interval
            version, ok = one_request(url, timeout)
            with lock:
                bucket = by_version.setdefault(version, {"ok": 0, "err": 0})
                bucket["ok" if ok else "err"] += 1

    threads = [threading.Thread(target=worker, args=(i,), daemon=True) for i in range(workers)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    total = sum(b["ok"] + b["err"] for b in by_version.values())
    errors = sum(b["err"] for b in by_version.values())
    return {
        "url": url,
        "seconds": round(time.monotonic() - started, 1),
        "total": total,
        "errors": errors,
        "error_rate_pct": round(100.0 * errors / total, 2) if total else 0.0,
        "by_version": by_version,
    }


def format_report(result: dict) -> str:
    lines = [f"  {result['total']} requests in {result['seconds']}s, "
             f"{result['errors']} failed ({result['error_rate_pct']}%)"]
    total = result["total"] or 1
    for version in sorted(result["by_version"]):
        b = result["by_version"][version]
        n = b["ok"] + b["err"]
        lines.append(f"    {version:<14} {n:>5} requests  ({100 * n // total:>3}%)   ok={b['ok']}  failed={b['err']}")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", default="http://127.0.0.1/api/version")
    ap.add_argument("--duration", type=float, default=10.0)
    ap.add_argument("--rps", type=float, default=20.0)
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--timeout", type=float, default=3.0)
    ap.add_argument("--stop-file", default="")
    ap.add_argument("--json", action="store_true", help="print the result as JSON")
    ap.add_argument("--report", metavar="FILE", help="pretty-print a saved JSON result and exit")
    ap.add_argument("--fail-on-errors", action="store_true", help="exit 1 if any request failed")
    args = ap.parse_args()

    if args.report:
        with open(args.report, encoding="utf-8") as fh:
            print(format_report(json.load(fh)))
        return 0

    result = run(args.url, args.duration, args.rps, args.workers, args.timeout, args.stop_file)
    print(json.dumps(result) if args.json else format_report(result))
    return 1 if (args.fail_on_errors and result["errors"]) else 0


if __name__ == "__main__":
    sys.exit(main())
