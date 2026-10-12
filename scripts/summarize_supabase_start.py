"""Print only allowlisted failure categories; never print raw startup output."""

import json
from pathlib import Path
import re
import sys


def summarize(text: str, migrations: list[str]) -> dict:
    patterns = {
        "disk_full": r"no space left on device|disk quota exceeded",
        "image_pull": r"failed to pull|pull access denied|manifest unknown|failed to resolve reference",
        "network": r"connection refused|connection reset|context deadline exceeded|TLS handshake|network is unreachable|i/o timeout",
        "health_check": r"unhealthy|health check|healthcheck|timed out waiting",
        "docker_unavailable": r"cannot connect to the docker|docker daemon is not running",
        "configuration": r"invalid config|failed to parse config|unknown config|missing environment",
        "migration": r"SQLSTATE|applying migration|failed to apply migration",
    }
    # Values in this result are fixed labels or repository-owned file names.
    # Unknown errors remain unknown instead of exposing arbitrary log text.
    return {
        "categories": [
            name for name, pattern in patterns.items()
            if re.search(pattern, text, re.IGNORECASE)
        ],
        "mentioned_migrations": [name for name in migrations if name in text],
        "known_sqlstates": [
            code for code in ("42P01", "42703", "23505", "42501", "42883", "42601", "0A000")
            if f"SQLSTATE {code}" in text
        ],
        "raw_log_omitted": True,
    }


if __name__ == "__main__":
    content = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
    names = sorted(path.name for path in Path("supabase/migrations").glob("*.sql"))
    print(json.dumps(summarize(content, names)))
