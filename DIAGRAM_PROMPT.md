# Diagram prompt (copy everything below into an image-generation model)

Create a clean, professional cloud infrastructure diagram, 16:9 landscape, white background, flat vector style, large readable labels, thin dark-grey lines, soft pastel fills. Title at the top: "Reverse Proxy and Zero-Downtime Deploys: everything on one EC2 instance".

LAYOUT, left to right.

LEFT: a "Browser (your laptop)" box with two small items: "http://<EC2-PUBLIC-IP>/" and "http://<EC2-PUBLIC-IP>/dashboard/". A solid arrow labeled "HTTP port 80" goes to the right. Below it a small "Terminal (SSH port 22)" box with a dashed arrow to the right.

MIDDLE: a thin firewall icon labeled "Security group: inbound SSH 22 and HTTP 80, both from my IP only; outbound all".

RIGHT: a large AWS-orange-bordered box labeled "AWS Region > Default VPC > EC2 instance m7i-flex.large (Ubuntu 24.04, 2 vCPU, 8 GiB)". Inside it, one big blue rounded box labeled "Docker Engine (Docker Compose stack: zd-box)". Inside the Docker box, place:
1. "nginx reverse proxy :80 (the only public port)" in the center, with a small file icon labeled "upstream.conf (traffic weights)".
2. "app-blue: version v1 (LIVE) :8080" in green, connected from nginx by a thick arrow labeled "weight 80-100%".
3. "app-green: version v2 (idle or canary) :8080" in yellow, connected from nginx by a thinner arrow labeled "weight 0-20% (canary)".
4. A box labeled "Release controller (scripts/release.sh)" with arrows labeled "1 deploy to idle slot", "2 health check /healthz", "3 rewrite upstream.conf", "4 nginx -s reload (graceful, no dropped requests)", "5 promote or rollback".
5. A box labeled "Load probe (tools/probe.py): 20 requests/second, counts failures per version" with an arrow into nginx.
6. A small box labeled "Live dashboard page (served by nginx at /dashboard/)" showing a row of coloured squares, mostly green with a few yellow and one red.

Add a small legend: green = live version, yellow = new version / canary, red = failed request, grey dashed = blocked release. Add a footer note: "No other AWS services. The load balancer role is played by nginx on the same instance."

Do not add any AWS services that are not listed (no ALB, ECS, ECR, S3, IAM, Route 53, RDS). Use generic icons, no brand logos other than a simple Docker whale. Make sure all text is spelled exactly as written above.
