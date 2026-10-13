#!/usr/bin/env bash
# Which admission verifier can check a cosign v3 signature? Kyverno 1.19.1 two ways, and Sigstore's policy-controller.
set -uo pipefail
IMG=ghcr.io/${GITHUB_REPOSITORY}/maright-app
ID="https://github.com/${GITHUB_REPOSITORY}/.github/workflows/build.yml@refs/heads/main"
ISS="https://token.actions.githubusercontent.com"
dig() { docker buildx imagetools inspect "$IMG:$1" --format '{{json .Manifest}}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["digest"])'; }
GOOD=$(dig v3.0.0); UNS=$(dig unsigned); OTHER=$(dig other); LEGACY=$(dig legacy)
try() { local out; out=$(kubectl run "$2" -n "$1" --image="$3" --restart=Never 2>&1)
  if [ $? -eq 0 ]; then echo "  $1/$2: ADMITTED"; else echo "  $1/$2: REJECTED: $(echo "$out" | tr '\n' ' ' | sed 's/.*denied the request: //' | cut -c1-900)"; fi; }
H() { echo; echo "=== $* ==="; }

H "Install Kyverno 3.9.1 directly"
helm install kyverno kyverno --repo https://kyverno.github.io/kyverno --version 3.9.1 -n kyverno --create-namespace --set admissionController.replicas=1 --set 'admissionController.container.extraArgs.enableTuf=true' --set 'admissionController.container.extraArgs.tufMirror=https://tuf-repo-cdn.sigstore.dev' --wait --timeout 8m >/dev/null && echo "installed with TUF on"
kubectl rollout status deploy/kyverno-admission-controller -n kyverno --timeout=180s >/dev/null; sleep 30
kubectl logs -n kyverno deploy/kyverno-admission-controller --tail=400 | grep -iE 'tuf|trusted root|sigstore' | cut -c1-220 | head -n 5
for ns in kb kl; do kubectl create namespace $ns >/dev/null; done

cat > /tmp/pol.yaml <<EOF
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: bundle-format
spec:
  webhookTimeoutSeconds: 30
  rules:
    - name: sigstore-bundle
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [kb]
      verifyImages:
        - type: SigstoreBundle
          imageReferences: ["ghcr.io/${GITHUB_REPOSITORY}/*"]
          failureAction: Enforce
          required: true
          attestors:
            - entries:
                - keyless:
                    subject: "$ID"
                    issuer: "$ISS"
                    rekor:
                      url: https://rekor.sigstore.dev
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: legacy-format
spec:
  webhookTimeoutSeconds: 30
  rules:
    - name: cosign-legacy
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [kl]
      verifyImages:
        - imageReferences: ["ghcr.io/${GITHUB_REPOSITORY}/*"]
          failureAction: Enforce
          required: true
          attestors:
            - entries:
                - keyless:
                    subject: "$ID"
                    issuer: "$ISS"
                    rekor:
                      url: https://rekor.sigstore.dev
EOF
for i in $(seq 12); do kubectl apply -f /tmp/pol.yaml >/dev/null 2>&1 && break; sleep 10; done
echo "policies: $(kubectl get clusterpolicy -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[0].status} {end}')"
sleep 15

H "A. Kyverno (TUF on), type SigstoreBundle (cosign v3 default signatures)"
try kb good "$IMG@$GOOD"; try kb other "$IMG@$OTHER"; try kb unsigned "$IMG@$UNS"; try kb legacy "$IMG@$LEGACY"

H "B. Kyverno (TUF on), classic type (older-format signature)"
try kl legacy "$IMG@$LEGACY"; try kl good "$IMG@$GOOD"
kubectl logs -n kyverno deploy/kyverno-admission-controller --since=5m 2>/dev/null | grep -iE 'x509|tuf|trusted|fulcio|bundle|verif' | grep -v flag.go | cut -c1-250 | tail -n 8

H "D. Sigstore policy-controller"
helm repo add sigstore https://sigstore.github.io/helm-charts >/dev/null && helm repo update >/dev/null
helm search repo sigstore/policy-controller | tail -n 1
helm install policy-controller sigstore/policy-controller -n cosign-system --create-namespace --wait --timeout 6m >/dev/null 2>&1 && echo installed || echo "install failed"
kubectl create namespace pc >/dev/null; kubectl label namespace pc policy.sigstore.dev/include=true >/dev/null
cat <<EOF | kubectl apply -f - 2>&1 | tail -n 1
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: mission
spec:
  images:
    - glob: "ghcr.io/${GITHUB_REPOSITORY}/**"
  authorities:
    - name: our-build
      keyless:
        url: https://fulcio.sigstore.dev
        identities:
          - issuer: "$ISS"
            subject: "$ID"
      ctlog:
        url: https://rekor.sigstore.dev
      signatureFormat: bundle
EOF
sleep 15
try pc good "$IMG@$GOOD"; try pc other "$IMG@$OTHER"; try pc unsigned "$IMG@$UNS"; try pc legacy "$IMG@$LEGACY"

kubectl logs -n cosign-system -l app.kubernetes.io/name=policy-controller --tail=200 2>/dev/null | grep -iE 'x509|bundle|tuf|trusted|error' | cut -c1-300 | tail -n 6
