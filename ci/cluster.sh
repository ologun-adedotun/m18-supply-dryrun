#!/usr/bin/env bash
# Module 18 authoring test: verification, admission, GitOps by digest, sealed secrets through a rebuild.
set -uo pipefail
source ci/lib.sh
ID="https://github.com/${GITHUB_REPOSITORY}/.github/workflows/build.yml@refs/heads/main"
ISS="https://token.actions.githubusercontent.com"
dig() { docker buildx imagetools inspect "$IMG:$1" --format '{{json .Manifest}}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["digest"])'; }
GOOD=$(dig v3.0.0); UNS=$(dig unsigned); NOSBOM=$(dig nosbom); OTHER=$(dig other)
echo "digests: v3.0.0=${GOOD:7:12} unsigned=${UNS:7:12} nosbom=${NOSBOM:7:12} other=${OTHER:7:12}"
histlen() { kubectl get application "$1" -n argocd -o jsonpath='{.status.history}' | python3 -c 'import json,sys; print(len(json.load(sys.stdin) or []))' 2>/dev/null; }
try() { # try NS NAME IMAGE: create a pod and report what admission said
  local out
  out=$(kubectl run "$2" -n "$1" --image="$3" --restart=Never 2>&1)
  if [ $? -eq 0 ]; then echo "$2: ADMITTED as $(kubectl get pod "$2" -n "$1" -o jsonpath='{.spec.containers[0].image}' | sed 's/@sha256:\(.\{12\}\).*/@sha256:\1.../')"
  else echo "$2: REJECTED: $(echo "$out" | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-330)"; fi
}

H "V. Verification outside the cluster"
cosign verify "$IMG@$GOOD" --certificate-identity "$ID" --certificate-oidc-issuer "$ISS" -o json 2>/tmp/v.err | python3 -c 'import json,sys; d=json.load(sys.stdin); print("v3.0.0 signature verified:", len(d), "signature(s); subject", d[0]["optional"].get("Subject"))'
tail -n 3 /tmp/v.err
echo "other.yml's image against our identity: $(cosign verify "$IMG@$OTHER" --certificate-identity "$ID" --certificate-oidc-issuer "$ISS" 2>&1 | tail -n 1 | cut -c1-250)"
echo "other.yml's image, its real identity: $(cosign verify "$IMG@$OTHER" --certificate-identity-regexp '.*' --certificate-oidc-issuer "$ISS" -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["optional"].get("Subject"))')"
echo "unsigned: $(cosign verify "$IMG@$UNS" --certificate-identity "$ID" --certificate-oidc-issuer "$ISS" 2>&1 | tail -n 1 | cut -c1-200)"
cosign verify-attestation "$IMG@$GOOD" --type spdxjson --certificate-identity "$ID" --certificate-oidc-issuer "$ISS" -o json 2>/dev/null | head -n 1 | python3 -c 'import json,sys,base64; e=json.loads(sys.stdin.readline()); p=json.loads(base64.b64decode(e["payload"])); print("SBOM attestation:", p["predicateType"], p["predicate"].get("spdxVersion"), len(p["predicate"].get("packages",[])), "packages")'
echo "provenance: $(gh attestation verify "oci://$IMG@$GOOD" --owner "${GITHUB_REPOSITORY%%/*}" 2>&1 | grep -iE 'verified|predicate|✓|error' | head -n 3 | tr '\n' ' ' | cut -c1-300)"
echo "what hangs off the image:"; cosign tree "$IMG@$GOOD" 2>/dev/null | grep -E 'Signatures|Attestations|SBOMs|└|├' | cut -c1-120 | head -n 8

H "K1. Platform from Git (image policy in Audit)"
installargo
kubectl apply -f deploy/bootstrap/root.yaml >/dev/null
waitall $APPS 900 | tail -n 3
kubectl get applications -n argocd
echo "Kyverno webhooks: $(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -i kyverno | tr '\n' ' ')"
echo "webhook namespaceSelector: $(kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg -o jsonpath='{.webhooks[0].namespaceSelector}' 2>/dev/null | cut -c1-250) failurePolicy=$(kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg -o jsonpath='{.webhooks[0].failurePolicy}' 2>/dev/null)"

H "K2. Audit: what gets through, and what is recorded"
try verify a-unsigned "$IMG@$UNS"
sleep 30
kubectl get policyreport -n verify -o json | python3 -c 'import json,sys
for r in json.load(sys.stdin)["items"]:
  for x in r.get("results",[]):
    print(" report:", x.get("policy"), x.get("rule"), x.get("result"), (x.get("message") or "")[:160])' | head -n 6
kubectl delete pod a-unsigned -n verify --wait=false >/dev/null 2>&1

H "K3. A tag in Git while Kyverno pins digests"
echo "staging image in Git: $(grep '  tag:' deploy/envs/staging/values.yaml)"
echo "Deployment's image in the cluster: $(kubectl get deploy mission -n staging -o jsonpath='{.spec.template.spec.containers[0].image}' | cut -c1-110)"
H0=$(histlen mission-staging)
for i in 1 2 3 4 5 6; do echo "$(ts) argo: $(short mission-staging) history=$(histlen mission-staging)"; sleep 10; done
echo "Argo CD operations during 60 s: $H0 -> $(histlen mission-staging)"

H "K4. Enforce"
sed -i 's/failureAction: Audit/failureAction: Enforce/' deploy/policies/verify-images.yaml
REV=$(push "Image policy: Enforce"); refresh policies; waitapp policies Synced Healthy "$REV" 240
sleep 10
try verify e-good-tag "$IMG:v3.0.0"
try verify e-good-digest "$IMG@$GOOD"
try verify e-unsigned "$IMG@$UNS"
try verify e-nosbom "$IMG@$NOSBOM"
try verify e-other "$IMG@$OTHER"
try verify e-latest "$IMG:latest"
try verify e-busybox busybox:latest
try verify e-notag busybox
kubectl delete pod -n verify --all --wait=false >/dev/null 2>&1

H "K5. GitOps by digest"
setval staging image.tag "v3.0.0@$GOOD"
REV=$(push "Staging: v3.0.0 by digest"); refresh mission-staging
waitapp mission-staging Synced Healthy "$REV" 300
H0=$(histlen mission-staging); sleep 60
echo "Argo CD operations in the next 60 s: $H0 -> $(histlen mission-staging); app $(short mission-staging)"
echo "Deployment's image: $(kubectl get deploy mission -n staging -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/@sha256:\(.\{12\}\).*/@sha256:\1.../')"

H "K6. An unsigned image through GitOps"
setval staging image.tag "unsigned@$UNS"
REV=$(push "Staging: an unsigned image"); T0=$(now); refresh mission-staging
sleep 60
echo "after 60 s: argo $(short mission-staging) $(kubectl get application mission-staging -n argocd -o jsonpath='{.status.health.message}' | cut -c1-120)"
kubectl get events -n staging --field-selector reason=FailedCreate -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' | tail -n 1 | cut -c1-400
echo "pods serving: $(kubectl get pods -n staging -l app.kubernetes.io/instance=mission --no-headers | awk '{print $1, $2, $3}' | tr '\n' ';')"
REV=$(revertpush); refresh mission-staging; waitapp mission-staging Synced Healthy "$REV" 300

H "K7. Kyverno down"
kubectl scale statefulset argocd-application-controller -n argocd --replicas=0 >/dev/null
kubectl scale deployment kyverno-admission-controller -n kyverno --replicas=0 >/dev/null
kubectl wait --for=delete pod -n kyverno -l app.kubernetes.io/component=admission-controller --timeout=120s >/dev/null 2>&1
sleep 5
try verify d-good "$IMG@$GOOD"
kubectl create namespace scratch >/dev/null
try scratch d-busybox busybox:1.37.0
try kube-system d-kube-system busybox:1.37.0
kubectl rollout restart deployment mission -n staging >/dev/null
sleep 30
echo "staging after a restart: $(kubectl get pods -n staging -l app.kubernetes.io/instance=mission --no-headers | awk '{print $2, $3}' | sort | uniq -c | tr '\n' ';')"
kubectl get events -n staging --field-selector reason=FailedCreate -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' | tail -n 1 | cut -c1-300
T0=$(now)
kubectl scale deployment kyverno-admission-controller -n kyverno --replicas=1 >/dev/null
kubectl rollout status deployment kyverno-admission-controller -n kyverno --timeout=180s >/dev/null
kubectl rollout status deployment mission -n staging --timeout=180s >/dev/null && echo "staging recovered $(( $(now) - T0 ))s after Kyverno returned"
kubectl scale statefulset argocd-application-controller -n argocd --replicas=1 >/dev/null
kubectl delete pod -n verify --all --wait=false >/dev/null 2>&1; kubectl delete pod -n scratch --all --wait=false >/dev/null 2>&1; kubectl delete pod d-kube-system -n kube-system --wait=false >/dev/null 2>&1

H "S1. A sealed secret"
kubectl rollout status deployment sealed-secrets-controller -n kube-system --timeout=120s >/dev/null
kubeseal --controller-namespace kube-system --fetch-cert > /tmp/cert.pem && echo "certificate fetched: $(openssl x509 -in /tmp/cert.pem -noout -subject -enddate | tr '\n' ' ')"
VAL=$(openssl rand -hex 16); echo "::add-mask::$VAL"
VHASH=$(printf '%s' "$VAL" | sha256sum | cut -c1-12)
kubectl create secret generic mission-api -n staging --from-literal=API_KEY="$VAL" --dry-run=client -o yaml | kubeseal --cert /tmp/cert.pem --format yaml > deploy/secrets/staging/mission-api.yaml
echo "plaintext in the sealed file: $(grep -c "$VAL" deploy/secrets/staging/mission-api.yaml)"; unset VAL
REV=$(push "Staging: a sealed API key"); refresh secrets
waitapp secrets Synced Healthy "$REV" 240
for i in $(seq 20); do kubectl get secret mission-api -n staging >/dev/null 2>&1 && break; sleep 3; done
echo "Secret in staging: value hash $(kubectl get secret mission-api -n staging -o jsonpath='{.data.API_KEY}' | base64 -d | sha256sum | cut -c1-12) (expected $VHASH)"
sed 's/namespace: staging/namespace: production/' deploy/secrets/staging/mission-api.yaml | kubectl apply -f - >/dev/null 2>&1
sleep 10
echo "the same sealed secret in production: $(kubectl get sealedsecret mission-api -n production -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{end}' | cut -c1-200); Secret: $(kubectl get secret mission-api -n production --no-headers 2>&1 | cut -c1-60)"
kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o json | python3 -c 'import json,sys
d=json.load(sys.stdin)
for i in d["items"]:
  for k in ("resourceVersion","uid","creationTimestamp","managedFields"): i["metadata"].pop(k, None)
json.dump(d, open("/tmp/sskey.json","w"))
print("controller keys backed up:", len(d["items"]))'

H "S2. Rebuild without the key"
kind delete cluster --name chart-testing >/dev/null 2>&1
T0=$(now)
kind create cluster --name rebuild --wait 120s >/dev/null 2>&1
installargo; kubectl apply -f deploy/bootstrap/root.yaml >/dev/null
waitall 7 600 | tail -n 2
echo "rebuilt in $(( $(now) - T0 ))s"
for i in $(seq 12); do m=$(kubectl get sealedsecret mission-api -n staging -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{end}' 2>/dev/null); [ -n "$m" ] && break; sleep 5; done
echo "sealed secret: ${m:-no status} | Secret: $(kubectl get secret mission-api -n staging --no-headers 2>&1 | cut -c1-60)"
echo "argo secrets app: $(short secrets) $(kubectl get application secrets -n argocd -o jsonpath='{.status.health.message}' | cut -c1-150)"
echo "staging pods admitted after the rebuild: $(kubectl get pods -n staging --no-headers | awk '{print $2, $3}' | sort | uniq -c | tr '\n' ';')"

H "S3. Restore the key"
kubectl apply -f /tmp/sskey.json >/dev/null && echo "key restored"
kubectl delete pod -n kube-system -l app.kubernetes.io/name=sealed-secrets >/dev/null
kubectl rollout status deployment sealed-secrets-controller -n kube-system --timeout=120s >/dev/null
T0=$(now)
for i in $(seq 40); do kubectl get secret mission-api -n staging >/dev/null 2>&1 && break; sleep 3; done
echo "Secret back $(( $(now) - T0 ))s after the controller restarted: hash $(kubectl get secret mission-api -n staging -o jsonpath='{.data.API_KEY}' | base64 -d | sha256sum | cut -c1-12) (expected $VHASH)"
rm -f /tmp/sskey.json
