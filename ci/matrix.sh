#!/usr/bin/env bash
# Which admission verifier can check a cosign v3 signature? Kyverno 1.19.1 two ways, and Sigstore's policy-controller.
set -uo pipefail
IMG=ghcr.io/${GITHUB_REPOSITORY}/maright-app
ID="https://github.com/${GITHUB_REPOSITORY}/.github/workflows/build.yml@refs/heads/main"
ISS="https://token.actions.githubusercontent.com"
dig() { docker buildx imagetools inspect "$IMG:$1" --format '{{json .Manifest}}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["digest"])'; }
GOOD=$(dig v3.0.0); UNS=$(dig unsigned); OTHER=$(dig other); LEGACY=$(dig legacy)
try() { local out; out=$(kubectl run "$2" -n "$1" --image="$3" --restart=Never 2>&1)
  if [ $? -eq 0 ]; then echo "  $1/$2: ADMITTED"; else echo "  $1/$2: REJECTED: $(echo "$out" | tr '\n' ' ' | sed 's/.*denied the request: //' | cut -c1-260)"; fi; }
H() { echo; echo "=== $* ==="; }

H "Install Kyverno 3.9.1 directly"
helm install kyverno kyverno --repo https://kyverno.github.io/kyverno --version 3.9.1 -n kyverno --create-namespace --set admissionController.replicas=1 --wait --timeout 8m >/dev/null && echo installed
kubectl logs -n kyverno deploy/kyverno-admission-controller --tail=400 | grep -iE 'tuf|trusted root|sigstore' | cut -c1-220 | head -n 5
for ns in kb kl; do kubectl create namespace $ns >/dev/null; done

cat <<EOF | kubectl apply -f - >/dev/null
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
echo "policies: $(kubectl get clusterpolicy -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[0].status} {end}')"
sleep 15

H "A. Kyverno, type SigstoreBundle (cosign v3 default signatures)"
try kb good "$IMG@$GOOD"; try kb other "$IMG@$OTHER"; try kb unsigned "$IMG@$UNS"; try kb legacy "$IMG@$LEGACY"

H "B. Kyverno, classic type (older-format signature)"
try kl legacy "$IMG@$LEGACY"; try kl good "$IMG@$GOOD"
kubectl logs -n kyverno deploy/kyverno-admission-controller --since=3m | grep -iE 'x509|tuf|root|fulcio|bundle' | cut -c1-250 | tail -n 6

H "C. Kyverno with its trust root refreshed from Sigstore's TUF repository"
helm upgrade kyverno kyverno --repo https://kyverno.github.io/kyverno --version 3.9.1 -n kyverno --reuse-values \
  --set 'admissionController.container.extraArgs.tufMirror=https://tuf-repo-cdn.sigstore.dev' --wait --timeout 6m >/dev/null 2>&1 && echo "upgraded with tufMirror" || echo "upgrade with tufMirror failed"
kubectl get deploy kyverno-admission-controller -n kyverno -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -i tuf
sleep 20
for p in kb kl; do kubectl delete pod --all -n $p --wait=false >/dev/null 2>&1; done; sleep 5
try kl legacy2 "$IMG@$LEGACY"; try kb good2 "$IMG@$GOOD"

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
