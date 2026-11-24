#!/usr/bin/env python3
"""Prometheus exporter for Jellyfin library statistics.

For every movie and TV library, exports item counts and total runtime:

  jellyfin_library_items{library="Movies", type="Movie"}
  jellyfin_library_runtime_seconds{library="Movies", type="Movie"}
  jellyfin_library_items{library="Shows", type="Series" | "Season" | "Episode"}
  jellyfin_library_runtime_seconds{library="Shows", type="Episode"}

Walking a whole library is relatively expensive, so results are cached for
CACHE_SECONDS and Prometheus scrapes are served from the cache.
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

JELLYFIN_URL = os.environ["JELLYFIN_URL"].rstrip("/")
API_KEY = os.environ["JELLYFIN_API_KEY"]
PORT = int(os.environ.get("PORT", "9711"))
CACHE_SECONDS = int(os.environ.get("CACHE_SECONDS", "300"))

TICKS_PER_SECOND = 10_000_000

# Library collection type -> item types to count. Types listed in RUNTIME_TYPES
# also get a total runtime (Series/Season runtimes are per-episode averages,
# not sums, so they are counted only).
TYPES_BY_COLLECTION = {
    "movies": ["Movie"],
    "tvshows": ["Series", "Season", "Episode"],
}
RUNTIME_TYPES = {"Movie", "Episode"}


def api(path, **params):
    url = f"{JELLYFIN_URL}{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(
        url, headers={"Authorization": f'MediaBrowser Token="{API_KEY}"'}
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.load(resp)


def collect():
    samples = []  # (metric, library, type, value)
    for folder in api("/Library/VirtualFolders"):
        item_types = TYPES_BY_COLLECTION.get(folder.get("CollectionType"))
        if not item_types:
            continue
        library = folder["Name"]
        for item_type in item_types:
            want_runtime = item_type in RUNTIME_TYPES
            params = {
                "ParentId": folder["ItemId"],
                "Recursive": "true",
                "IncludeItemTypes": item_type,
                # Exclude placeholder entries for episodes/seasons Jellyfin
                # knows about from metadata but that aren't on disk.
                "IsMissing": "false",
                "EnableImages": "false",
                "EnableUserData": "false",
                "EnableTotalRecordCount": "true",
            }
            if not want_runtime:
                params["Limit"] = "0"
            result = api("/Items", **params)
            samples.append(
                ("jellyfin_library_items", library, item_type, result["TotalRecordCount"])
            )
            if want_runtime:
                ticks = sum(i.get("RunTimeTicks") or 0 for i in result["Items"])
                samples.append(
                    (
                        "jellyfin_library_runtime_seconds",
                        library,
                        item_type,
                        ticks / TICKS_PER_SECOND,
                    )
                )
    return samples


def escape(value):
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


HELP = {
    "jellyfin_library_items": "Number of items in a Jellyfin library, by item type.",
    "jellyfin_library_runtime_seconds": "Total runtime of items in a Jellyfin library, by item type.",
}


def render(samples, up, duration):
    lines = []
    for metric, help_text in HELP.items():
        lines.append(f"# HELP {metric} {help_text}")
        lines.append(f"# TYPE {metric} gauge")
        for name, library, item_type, value in samples:
            if name == metric:
                lines.append(
                    f'{metric}{{library="{escape(library)}",type="{escape(item_type)}"}} {value}'
                )
    lines.append("# HELP jellyfin_up Whether the last Jellyfin API query succeeded.")
    lines.append("# TYPE jellyfin_up gauge")
    lines.append(f"jellyfin_up {1 if up else 0}")
    lines.append("# HELP jellyfin_collect_duration_seconds Time taken by the last Jellyfin API query.")
    lines.append("# TYPE jellyfin_collect_duration_seconds gauge")
    lines.append(f"jellyfin_collect_duration_seconds {duration}")
    return "\n".join(lines) + "\n"


_cache = {"at": 0.0, "body": ""}


def metrics():
    now = time.monotonic()
    if _cache["body"] and now - _cache["at"] < CACHE_SECONDS:
        return _cache["body"]
    start = time.monotonic()
    try:
        samples, up = collect(), True
    except Exception as exc:  # report failure as jellyfin_up 0, keep serving
        print(f"collect failed: {exc!r}", file=sys.stderr, flush=True)
        samples, up = [], False
    body = render(samples, up, time.monotonic() - start)
    # Don't cache failures, so the next scrape retries.
    if up:
        _cache.update(at=now, body=body)
    return body


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_error(404)
            return
        body = metrics().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    HTTPServer(("", PORT), Handler).serve_forever()
