#!/usr/bin/env bash
# Module 18 authoring test: verification, admission, GitOps by digest, sealed secrets through a rebuild.
set -uo pipefail
source ci/lib.sh
ID="https://github.com/${GITHUB_REPOSITORY}/.github/workflows/build.yml@refs/heads/main"
ISS="https://token.actions.githubusercontent.com"
dig() { docker buildx imagetools inspect "$IMG:$1" --format '{{json .Manifest}}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["digest"])'; }
GOOD=$(dig v3.0.0); UNS=$(dig unsigned); NOSBOM=$(dig nosbom); OTHER=$(dig other); LEGACY=$(dig legacy)
echo "digests: v3.0.0=${GOOD:7:12} unsigned=${UNS:7:12} nosbom=${NOSBOM:7:12} other=${OTHER:7:12}"
histlen() { kubectl get application "$1" -n argocd -o jsonpath='{.status.history}' | python3 -c 'import json,sys; print(len(json.load(sys.stdin) or []))' 2>/dev/null; }
try() { # try NS NAME IMAGE: create a pod and report what admission said
  local out
  out=$(kubectl run "$2" -n "$1" --image="$3" --restart=Never 2>&1)
  if [ $? -eq 0 ]; then echo "$2: ADMITTED as $(kubectl get pod "$2" -n "$1" -o jsonpath='{.spec.containers[0].image}' | sed 's/@sha256:\(.\{12\}\).*/@sha256:\1.../')"
  else echo "$2: REJECTED: $(echo "$out" | tr '\n' ' ' | sed 's/  */ /g' | sed 's/.*blocked due to the following policies //' | cut -c1-700)"; fi
}

fallback() { # if a child is stuck, show its diff and apply the remaining Applications directly
  if [ "$(kubectl get application kyverno -n argocd -o jsonpath='{.status.sync.status}')" != Synced ]; then
    echo "kyverno still OutOfSync; first lines of its diff:"
    kubectl config set-context --current --namespace=argocd >/dev/null
    argocd app diff kyverno --core 2>&1 | head -n 40
    kubectl config set-context --current --namespace=default >/dev/null
    echo "FALLBACK: applying the remaining platform Applications directly"
    kubectl apply -f deploy/platform/ >/dev/null
    waitall 7 600 | tail -n 2
  fi
}
H "K1. Platform from Git (image policy in Audit)"
curl -sSL -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/download/v3.5.5/argocd-linux-amd64 && sudo install -m 0755 /tmp/argocd /usr/local/bin/argocd
installargo
kubectl apply -f deploy/bootstrap/root.yaml >/dev/null
waitall $APPS 420 | tail -n 3
fallback
kubectl get applications -n argocd
for a in mission-staging policies; do echo "$a: op=$(kubectl get application $a -n argocd -o jsonpath='{.status.operationState.phase} {.status.operationState.message}' | cut -c1-400) conditions=$(kubectl get application $a -n argocd -o jsonpath='{range .status.conditions[*]}{.type}: {.message}; {end}' | cut -c1-400)"; done
for a in $(kubectl get applications -n argocd -o jsonpath='{range .items[?(@.status.sync.status!="Synced")]}{.metadata.name} {end}'); do echo "$a OutOfSync: $(kubectl get application $a -n argocd -o jsonpath='{range .status.resources[?(@.status=="OutOfSync")]}{.kind}/{.name} {end}' | cut -c1-300)"; done
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
sed -i 's/failureAction: Audit/failureAction: Enforce/; s/mutateDigest: false/mutateDigest: true/' deploy/policies/verify-images.yaml
REV=$(push "Image policy: Enforce"); refresh policies; waitapp policies Synced Healthy "$REV" 240
sleep 10
try verify e-good-tag "$IMG:v3.0.0"
try verify e-good-digest "$IMG@$GOOD"
try verify e-unsigned "$IMG@$UNS"
try verify e-nosbom "$IMG@$NOSBOM"
try verify e-other "$IMG@$OTHER"
try verify e-legacy "$IMG@$LEGACY"
if kubectl get pod e-legacy -n verify >/dev/null 2>&1 && ! kubectl get pod e-good-digest -n verify >/dev/null 2>&1; then echo "ONLY the older signature format is accepted: using the legacy image for GitOps"; GOOD=$LEGACY; GTAG=legacy; else GTAG=v3.0.0; fi
try verify e-latest "$IMG:latest"
try verify e-busybox busybox:latest
try verify e-notag busybox
kubectl delete pod -n verify --all --wait=false >/dev/null 2>&1

H "K5. GitOps by digest"
setval staging image.tag "${GTAG}@$GOOD"
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
echo "webhooks while Kyverno is down: $(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -ci kyverno) Kyverno webhook configurations; resource webhook failurePolicy=$(kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg -o jsonpath='{.webhooks[*].failurePolicy}' 2>&1 | cut -c1-80)"
echo "admission endpoints: $(kubectl get endpointslices -n kyverno -l kubernetes.io/service-name=kyverno-svc -o jsonpath='{.items[*].endpoints}' | cut -c1-80)"
try verify d-good "$IMG@$GOOD"
try verify d-unsigned "$IMG@$UNS"
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

