# Demo cheat sheet (1-minute read)

**What it does:** It releases a new version of a website while people are using it, and nobody notices. If the new version is bad, the system stops it or undoes it by itself.

**How it works:**
1. nginx (a "reverse proxy") is the front door. All visitors hit it at `http://<PUBLIC-IP>/`.
2. Behind it are two copies of the app: **blue** (live) and **green** (idle).
3. A new version is installed on the idle copy. Nobody sees it yet.
4. A health check tests it. If it fails, the release is blocked.
5. A one-line change tells nginx to send visitors to the new copy. The old copy keeps running, so undoing is instant.
6. Instead of switching everyone at once, a **canary** sends a small share (say 20%) first.

**Example 1: clean release (`./scripts/demo.sh bluegreen`)**
Version 1 is live. Release version 2 while 20 requests per second flow in. The dashboard colour changes from one version to the next, and the report says "0 failed requests". Visitors never saw an error.

**Example 2: bad release caught (`./scripts/demo.sh bad-canary`)**
Version 2 starts fine but fails about 1 in 3 real requests. Only 10% of visitors get it. The system sees the errors, cuts it off within seconds and sends everyone back to version 1. Without a canary, every visitor would have hit the bug.

**Show:** keep `http://<PUBLIC-IP>/dashboard/` open. Each square is one request. Colour = version. Red = failed.

**If asked "why not just restart the app?"** A restart drops requests for a few seconds. Here the old version serves until the new one is proven healthy.
