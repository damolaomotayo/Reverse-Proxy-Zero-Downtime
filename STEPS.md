# STEPS: Reverse Proxy and Zero-Downtime Deploys

## Prerequisites (set these up BEFORE step 1)

| Need | Details |
|---|---|
| **AWS account** | Any account that can launch EC2. No IAM role, no other AWS service. Use one region for everything below. |
| **Instance type** | `m7i-flex.large` (2 vCPU, 8 GiB). This project needs under 1 GiB, so it is very light. |
| **OS image (AMI)** | Ubuntu Server 24.04 LTS (64-bit x86). 22.04 also works. |
| **Disk** | 20 GiB gp3. |
| **Key pair** | An RSA `.pem` key pair created in EC2 (step 0a). |
| **Security group** | Created in step 0b. **Inbound: exactly two rules: (1) SSH, TCP port 22, source My IP; (2) Custom TCP, port 80, source My IP.** **Outbound: leave the default (All traffic, 0.0.0.0/0)**, because the instance must reach Docker Hub, Ubuntu's apt mirrors and Docker's apt repo. No other ports are needed. |
| **Code on the instance** | Option A: private GitHub repo plus a fine-grained token (Contents: Read) used as the password for `git clone`. Option B: copy the zip with `scp` (step 2). |
| **Accounts / tokens** | None else. No Docker Hub login needed (a free one helps if pulls get rate-limited, see troubleshooting). |
| **On your laptop** | A terminal with `ssh`/`scp` and a web browser. **No SSH tunnel is needed:** you open the site directly at `http://<PUBLIC-IP>/`. |

**Time:** about 10 minutes of setup, 3 minutes for the full demo. **Cost:** about $0.10/hour at your quoted rate, plus pennies for the disk. Do step 12 when finished.

---

## Step 0: Create the key pair, security group and instance (AWS console)

**0a. Key pair.** EC2 > Network & Security > Key pairs > **Create key pair**. Name `zd-box-key`, type **RSA**, format **.pem**. The file downloads once; keep it safe. On your laptop, lock down its permissions:

```bash
# Linux / macOS
chmod 400 ~/Downloads/zd-box-key.pem
```
```powershell
# Windows PowerShell (OpenSSH)
icacls "$HOME\Downloads\zd-box-key.pem" /inheritance:r /grant:r "$($env:USERNAME):(R)"
```

**0b. Security group.** EC2 > Network & Security > Security Groups > **Create security group**.
- Name: `zd-box-sg`, Description: `SSH and HTTP from my IP`, VPC: the default VPC.
- **Inbound rules > Add rule** (do it twice):
  1. Type `SSH`, Protocol `TCP`, Port range `22`, Source `My IP`
  2. Type `Custom TCP`, Protocol `TCP`, Port range `80`, Source `My IP`
- **Outbound rules:** leave the default rule (Type `All traffic`, Destination `0.0.0.0/0`).
- Click **Create security group**.

> Showing the demo to someone on a different network? Their browser is blocked by "My IP". Either share your screen, or edit the port 80 rule and add their address as a second rule (Custom TCP, port 80, Source = their public IP followed by `/32`). Do not use `0.0.0.0/0`.

**0c. Launch the instance.** EC2 > Instances > **Launch instances**.
- Name: `zd-box`
- Application and OS Image: **Ubuntu**, choose **Ubuntu Server 24.04 LTS**, architecture **64-bit (x86)**
- Instance type: `m7i-flex.large`
- Key pair: `zd-box-key`
- Network settings > **Edit**: Auto-assign public IP **Enable**; Firewall: **Select existing security group** > `zd-box-sg`
- Configure storage: **20 GiB**, `gp3`
- Advanced details > IAM instance profile: leave as **No IAM role**
- Click **Launch instance**, wait until Instance state is `Running` and Status check is `2/2 passed`, then copy the **Public IPv4 address**. This is your `<PUBLIC-IP>` below.

> If your home or phone network changes later, SSH and the browser page will time out because "My IP" no longer matches. Edit **both** inbound rules of `zd-box-sg` and set Source to My IP again. Stopping and starting the instance also gives it a new public IP.

## Step 1: Connect to the instance (from your laptop)

```bash
ssh -i ~/Downloads/zd-box-key.pem ubuntu@<PUBLIC-IP>
```
Type `yes` at the fingerprint prompt. Every command from here to step 11 runs **on the instance**.

## Step 2: Update packages and get the code

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y git unzip
```

**Option A (private GitHub repo):**
```bash
git clone https://github.com/<you>/reverse-proxy-zero-downtime.git
cd reverse-proxy-zero-downtime
```
When asked, username = your GitHub username, password = the fine-grained token.

**Option B (no GitHub), run from your laptop in the folder holding the zip, then continue on the instance:**
```bash
# on your laptop
scp -i ~/Downloads/zd-box-key.pem reverse-proxy-zero-downtime.zip ubuntu@<PUBLIC-IP>:~
# on the instance
unzip reverse-proxy-zero-downtime.zip
cd reverse-proxy-zero-downtime
```

## Step 3: Make the scripts executable (do not skip)

Files that were zipped, uploaded to GitHub or copied between systems often lose their "executable" flag. Without this you get `Permission denied`.

```bash
chmod +x scripts/*.sh tools/*.py
ls -l scripts/        # every .sh line should start with -rwxr-xr-x
```

## Step 4: Install Docker and Compose

```bash
./scripts/setup.sh
```
It runs `apt update`/`upgrade`, installs `ca-certificates curl git gnupg openssl python3 unzip`, installs Docker Engine and Compose v2 from Docker's official repo (falling back to Ubuntu's `docker.io` package if that repo is unreachable), starts Docker and prints the versions. Takes 3-5 minutes. It ends with `Setup complete.`

## Step 5: Unit tests

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
```
Ends with `OK`. (One test is skipped if PyYAML is not installed; that is fine.)

## Step 6: Preflight (run this well before the demo)

```bash
./scripts/preflight.sh
```
Pulls every image, builds the app image, syntax-checks the nginx config and runs the tests. Every line must say `ok`, and the last line is `Preflight passed. Safe to run ./scripts/up.sh`. First run takes 2-3 minutes.

## Step 7: Start everything

```bash
./scripts/up.sh
```
Builds the app, starts nginx plus the blue and green slots (both on v1, blue live) and prints your URLs. Takes about 1 minute. Example output:

```
Site       : http://<PUBLIC-IP>/
Dashboard  : http://<PUBLIC-IP>/dashboard/
```

## Step 8: Health check

```bash
./scripts/smoke.sh
```
Every line says `ok` and it ends with **`All 15 checks passed.`** (It includes a test that reloads nginx twice under load and drops zero requests.)

## Step 9: Open the dashboard in your browser (on your laptop)

Open `http://<PUBLIC-IP>/dashboard/` and leave it open. You see a grid of coloured squares, one per request, and a bar showing the traffic split by version. Right now it is all one colour (v1). Also try `http://<PUBLIC-IP>/` (a big coloured page showing the version).

## Step 10: Run the demo (on the instance)

```bash
./scripts/demo.sh all           # all five scenarios, about 3-4 minutes
```
Or one at a time (each starts from a clean baseline):
```bash
./scripts/demo.sh bluegreen     # v1 -> v2 switched live under load, zero failed requests
./scripts/demo.sh canary        # 20% of users get v2, then promote
./scripts/demo.sh bad-health    # broken release is blocked before users see it
./scripts/demo.sh bad-canary    # release that passes startup but fails real traffic is rolled back automatically
./scripts/demo.sh rollback      # promote, then undo instantly
```
Each scenario ends with a green `PASS`. The red `BLOCKED` lines inside `bad-health` and `bad-canary` are expected: that is the safety net working. Watch the dashboard while they run.

Manual control (good for a live demo, one command at a time):
```bash
./scripts/release.sh status                 # who runs what, where traffic goes
./scripts/release.sh deploy v2              # new version on the idle slot, 0% traffic
./scripts/release.sh canary 20              # 20% of users to v2 (watch the dashboard)
./scripts/release.sh promote                # everyone to v2
./scripts/release.sh rollback               # back to v1 instantly
./scripts/release.sh deploy v3 errors       # a version that looks healthy but fails 30% of requests
./scripts/release.sh canary 10 --watch 15   # ... caught and rolled back automatically
./scripts/release.sh reset                  # back to the baseline
```

## Step 11: Useful commands

```bash
sudo docker compose ps                      # the three containers
sudo docker compose logs --tail 20 nginx    # access log: shows ver=<version> for every request
curl -I http://localhost/api/version        # response header X-App-Version shows who answered
cat nginx/upstream/upstream.conf            # the live traffic weights
```

## Step 12: Clean up, then terminate the instance

```bash
./scripts/destroy.sh
```
Then in the AWS console: EC2 > Instances > select `zd-box` > **Instance state > Terminate instance**. Optionally delete the `zd-box-sg` security group and `zd-box-key` key pair too.

---

## What you should see

| Step | Result |
|---|---|
| 5 | Tests end with `OK` |
| 6 | All `ok`, then `Preflight passed.` |
| 7 | `Stack is up.` with two URLs containing your public IP |
| 8 | `All 15 checks passed.` |
| 9 | Dashboard loads at `http://<PUBLIC-IP>/dashboard/`, all squares one colour |
| 10 | `bluegreen`: squares change colour, none turn red. `canary`: about 1 in 5 squares in the new colour. `bad-canary`: a few red squares, then all back to the old colour. Every scenario ends `PASS`. |

## Risky dependencies and fallbacks

| Dependency | Risk | Fallback |
|---|---|---|
| Docker Hub images (`nginx:1.27-alpine`, `python:3.12-slim`) | Rate limit or a withdrawn tag | `sudo docker login` with a free account, or change the tag in `.env` (e.g. `NGINX_IMAGE=nginx:stable-alpine`) and re-run `./scripts/preflight.sh` |
| `download.docker.com` (Docker apt repo) | Unreachable | `setup.sh` falls back to Ubuntu's `docker.io` automatically |
| github.com, PyPI | **Not used** | none needed |

## If something goes wrong

| Symptom | Fix |
|---|---|
| SSH: `Connection timed out` | Your IP changed. Edit security group `zd-box-sg`, inbound rule SSH port 22, Source My IP. Also confirm the instance is Running and has a public IP. |
| Browser: page never loads at `http://<PUBLIC-IP>/` | (1) Use `http://` not `https://`. (2) The port 80 inbound rule must exist with Source My IP (re-select My IP if your network changed). (3) Check the IP is the instance's current public IP. (4) On the instance: `curl -I http://localhost/` should return `200`. If that works, the problem is the security group, not the app. |
| Testing the public IP from the instance itself hangs | Expected: the security group only allows your laptop's IP. Test from the laptop browser, or use `http://localhost/` on the instance. |
| SSH: `Permission denied (publickey)` | Use user `ubuntu` (not `ec2-user`), the right `.pem`, and `chmod 400` on it. |
| SSH: `UNPROTECTED PRIVATE KEY FILE` | `chmod 400 zd-box-key.pem` |
| `./scripts/x.sh: Permission denied` | `chmod +x scripts/*.sh tools/*.py` (step 3). Or run with `bash scripts/x.sh`. |
| `bad interpreter: /usr/bin/env bash^M` | Windows line endings. Run `sed -i 's/\r$//' scripts/*.sh` |
| `permission denied` on the Docker socket | The scripts use `sudo` for you. For manual commands use `sudo docker ...`, or log out and back in once. |
| Preflight: image pull fails | `sudo docker login` (free account) and re-run, or change the tag in `.env`. Check the outbound rule is All traffic. |
| Preflight: `Port 80 is free` fails | `sudo ss -ltnp \| grep ':80 '`, stop what uses it (often apache2 or nginx: `sudo systemctl disable --now apache2 nginx`), or `./scripts/destroy.sh` if it is an old run of this project. |
| `up.sh`: a slot did not become healthy | `sudo docker compose logs --tail 30 app-blue` (or `app-green`) |
| Smoke: reload test fails | Wait 10 seconds and run `./scripts/smoke.sh` again (the first requests after startup can be slow). |
| Dashboard squares are all grey | The browser cannot reach the site: see the "page never loads" row. |
| `release.sh canary` says `not healthy` | Run `./scripts/release.sh deploy <version>` first. |
| Messy state after experimenting | `./scripts/release.sh reset` |
| Disk full | `sudo docker system prune -af` |
