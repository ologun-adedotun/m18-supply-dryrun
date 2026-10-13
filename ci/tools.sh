#!/usr/bin/env bash
# Syft, Grype, kubeseal and gitleaks, each checked against the checksum its project publishes.
set -euo pipefail
get() { # URL SHA256 BINARY
  curl -sSL -o /tmp/t.tgz "$1"
  echo "$2  /tmp/t.tgz" | sha256sum -c --quiet
  tar -xzf /tmp/t.tgz -C /tmp "$3"
  sudo install -m 0755 "/tmp/$3" "/usr/local/bin/$3"
}
get https://github.com/anchore/syft/releases/download/v1.54.1/syft_1.54.1_linux_amd64.tar.gz c069905b391cc4c20a5ba65ad5c10be2a7ba074f8ea6ad203e24d14e303dad47 syft
get https://github.com/anchore/grype/releases/download/v0.120.1/grype_0.120.1_linux_amd64.tar.gz 0a9ee97ef5ae2ee953b0a80098105052e846cdbe319a57d808b519c33cd1343d grype
get https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.40.0/kubeseal-0.40.0-linux-amd64.tar.gz 9314c35916646e9d59c8f06b1314574b4e79c4d76f079433607ed7b697bb5eb7 kubeseal
get https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz 551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb gitleaks
syft version | grep -i '^version'; grype version | grep -i '^version'; kubeseal --version; gitleaks version