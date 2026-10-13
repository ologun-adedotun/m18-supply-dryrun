#!/usr/bin/env bash
# Demonstrations that must fail, and a base-image comparison. Never stops the job.
set -uo pipefail
IMG=ghcr.io/${GITHUB_REPOSITORY}/maright-app

echo "=== An expired exception ==="
python3 ci/check-exceptions.py security/exceptions-expired-example.yaml /tmp/x.yaml; echo "exit $?"

echo "=== An image with an old dependency ==="
sed 's/requirements.txt/requirements.vuln.txt/g' app/Dockerfile > /tmp/Dockerfile.vuln
docker build -q -f /tmp/Dockerfile.vuln -t vuln-test app >/dev/null
grype vuln-test --only-fixed --fail-on high -q -o table > /tmp/vuln.txt; rc=$?
echo "grype exit $rc"; grep -iE 'requests|urllib3' /tmp/vuln.txt | head -n 8
echo "by severity (fixable only): $(awk 'NR>1{print $NF}' /tmp/vuln.txt | sort | uniq -c | tr '\n' ' ')"

echo "=== Base images: known vulnerabilities by severity (all, then fixable only) ==="
for b in python:3.12-slim@sha256:a6e34c598f2467ed0e9a8d349809fcd8b5c603269512df273a0bb1784edc11b1 \
         python:3.12-alpine@sha256:1b668429b3511ab407d8e00648891631b0b1a4d7e15e3ca70f38ab5b91ad4ab4; do
  all=$(grype "$b" -q -o json | python3 -c 'import json,sys,collections; d=json.load(sys.stdin)["matches"]; c=collections.Counter(m["vulnerability"]["severity"] for m in d); print(len(d), dict(c))')
  fix=$(grype "$b" -q --only-fixed -o json | python3 -c 'import json,sys,collections; d=json.load(sys.stdin)["matches"]; c=collections.Counter(m["vulnerability"]["severity"] for m in d); print(len(d), dict(c))')
  echo "${b%@*}: all $all | fixable $fix"
done
echo "app image v3.0.0 (slim base + our packages): $(grype "$IMG:v3.0.0" -q -o json | python3 -c 'import json,sys,collections; d=json.load(sys.stdin)["matches"]; c=collections.Counter(m["vulnerability"]["severity"] for m in d); print(len(d), dict(c))')"

echo "=== gitleaks against a planted fake key (not committed) ==="
mkdir -p /tmp/leak && printf 'token = "ghp_%s"\n' "$(head -c 200 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 36)" > /tmp/leak/config.py
gitleaks dir /tmp/leak --redact --no-banner --exit-code 1 2>&1 | tail -n 6; echo "exit ${PIPESTATUS[0]}"

echo "=== Every action pinned by a full commit SHA? ==="
grep -hE '^\s*-?\s*uses:' .github/workflows/*.yml | sed 's/^ *- *//; s/^ *//' | sort -u | while read -r _ ref _; do
  if [[ "$ref" =~ @[0-9a-f]{40}$ ]]; then echo "pinned   $ref"; else echo "NOT PINNED $ref"; fi
done
