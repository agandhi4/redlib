"""Container healthcheck: exit 0 if /health/ready answers 2xx, else 1.

Readiness, not liveness: /health/live answers 200 unconditionally, so a container probing it
would report healthy against a dead database (observability.md, Health Contract).
"""

import sys
import urllib.request

try:
    # urlopen raises for 4xx/5xx, so the 503 from a down dependency fails here.
    urllib.request.urlopen("http://127.0.0.1:8000/health/ready", timeout=4)
except Exception:
    sys.exit(1)
