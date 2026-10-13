"""Refuse expired or unexplained vulnerability exceptions, and write Grype's ignore list."""
import datetime
import sys

import yaml

src, out = sys.argv[1], sys.argv[2]
entries = (yaml.safe_load(open(src)) or {}).get("exceptions") or []
today = datetime.date.today()
problems = []
ignore = []
for e in entries:
    vid = e.get("vulnerability", "?")
    for field in ("vulnerability", "package", "reason", "owner", "expires"):
        if not e.get(field):
            problems.append(f"{vid}: missing {field}")
    expires = e.get("expires")
    if isinstance(expires, str):
        expires = datetime.date.fromisoformat(expires)
    if expires and expires < today:
        problems.append(f"{vid}: expired on {expires}")
    ignore.append({"vulnerability": vid, "package": {"name": e.get("package")}})
if problems:
    print("Exceptions refused:")
    for p in problems:
        print("  " + p)
    sys.exit(1)
yaml.safe_dump({"ignore": ignore}, open(out, "w"))
print(f"{len(ignore)} exception(s) accepted")