# Reverse Proxy and Zero-Downtime Deploys

An nginx reverse proxy in front of two copies of an app (**blue** and **green**) on **one EC2 instance**. A release controller deploys a new version to the idle copy, health-checks it, then moves traffic over with blue-green or canary releases. A background load of 20 requests/second proves that nothing is dropped, and a live dashboard shows every request, coloured by the version that answered it.

**Start with [STEPS.md](STEPS.md)**: prerequisites first (including the exact security group rules and every `chmod`), then copy-paste commands. **Presenting it? Read [DEMO.md](DEMO.md) first.**

```
 browser ──http://<EC2-PUBLIC-IP>/──────────▶ nginx :80 (the only public port)
          ──http://<EC2-PUBLIC-IP>/dashboard/        │  weights from nginx/upstream/upstream.conf
                                                      ├── weight 100-N ──▶ app-blue   (v1, live)
                                                      └── weight N ──────▶ app-green  (v2, canary or idle)

 scripts/release.sh  deploy ▶ health gate ▶ canary N% (auto-watch) ▶ promote ▶ rollback
        │ rewrites upstream.conf, runs "nginx -t", then "nginx -s reload" (graceful, drops nothing)
        └─ tools/probe.py sends 20 req/s and records which version answered each one
```

## What's in it

| Piece | What it demonstrates |
|---|---|
| `nginx/default.conf` | Reverse proxy with a weighted upstream, retries only on connection failures, a version header on every response |
| `nginx/upstream/upstream.conf` (generated) | The traffic split. A weight of 0 becomes `down` |
| `app/` | A tiny versioned web app with fault injection: `health` (fails the health check) and `errors` (healthy on startup, fails 30% of real requests) |
| `scripts/release.sh` | `deploy`, `canary` (with automatic rollback), `promote`, `rollback`, `status`, `reset` |
| `tools/probe.py` | Load generator that counts requests and failures per version |
| `dashboard/` | Live page: one square per request, coloured by version, red when failed |
| `scripts/demo.sh` | Five self-checking scenarios, each ending in `PASS` or `FAIL` |

## The demo scenarios

| Scenario | What happens | Expected result |
|---|---|---|
| `bluegreen` | v2 goes to the idle slot, then all traffic is switched, under load | 0 failed requests, v1 then v2 seen |
| `canary` | 20% of traffic to v2, then promote | v2 gets about 20%, 0 failures |
| `bad-health` | v2 started with a failing health check | Release blocked, v1 untouched |
| `bad-canary` | v2 is "healthy" but fails 30% of real requests, 10% canary | Canary rolled back automatically within seconds |
| `rollback` | Promote v2, then roll back | v1 back instantly, 0 failures |

## Key ideas to be able to explain

- **Reverse proxy:** one stable front door; what sits behind it can change without visitors noticing.
- **Blue-green:** two identical environments. Release to the idle one, test it, flip traffic, keep the old one for instant rollback.
- **Canary:** expose a small share of real users first and watch for errors before committing.
- **Health gate vs canary:** a health check catches "will not start"; only real traffic catches "starts fine but breaks under use". The `errors` fault shows the difference.
- **Graceful reload:** `nginx -s reload` starts new workers on the new config while old workers finish their requests, so no connection is cut. The smoke test reloads under load and checks zero failures.
- **Retry rules:** nginx retries another server only when a connection fails, never on HTTP 500, so bad releases stay visible instead of being hidden.
- **Simulating cloud services:** nginx plays the role of a load balancer (ALB) and the two containers play two target groups, all on one instance.

## Repo layout

```
README.md  STEPS.md  DEMO.md  DIAGRAM_PROMPT.md  .env.example  docker-compose.yml
app/               app.py, Dockerfile                     versioned app with fault injection
nginx/             default.conf, upstream/ (generated)    proxy config and traffic weights
dashboard/         index.html                             live traffic page
tools/             probe.py                               load generator and reporter
scripts/           lib.sh setup.sh preflight.sh up.sh release.sh demo.sh smoke.sh destroy.sh
tests/             unit tests for the app and probe, plus repo sanity tests
```

## Limitations (kept simple on purpose)

- **Plain HTTP on port 80**, no TLS or domain name. A real setup would add HTTPS (for example Let's Encrypt).
- **Port 80 is open only to your IP** through the security group. Anyone else needs their address added.
- **One nginx, one instance:** the proxy itself is a single point of failure. Real systems run several behind a cloud load balancer.
- **The app is stateless.** Releases that change a database schema need extra care (expand/contract migrations) that this demo does not cover.
- **The canary check is simple:** it compares the error rate of the new version over a short window. Production setups also watch latency and business metrics.
- **Pinned images** (`nginx:1.27-alpine`, `python:3.12-slim`) can be changed in `.env` if one is ever withdrawn.
