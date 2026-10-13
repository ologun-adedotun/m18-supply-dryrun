{{- define "maright-app.fullname" -}}
{{- printf "%s" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "maright-app.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "maright-app.labels" -}}
{{ include "maright-app.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/* The pod template, shared by the Deployment and the Rollout. */}}
{{- define "maright-app.podTemplate" -}}
metadata:
  labels:
    {{- include "maright-app.labels" . | nindent 4 }}
  annotations:
    checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
    prometheus.io/scrape: "true"
    prometheus.io/port: "8000"
spec:
  serviceAccountName: {{ include "maright-app.fullname" . }}
  terminationGracePeriodSeconds: {{ .Values.shutdown.terminationGracePeriodSeconds }}
  {{- if .Values.topologySpread.enabled }}
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: DoNotSchedule
      labelSelector:
        matchLabels:
          {{- include "maright-app.selectorLabels" . | nindent 10 }}
  {{- end }}
  automountServiceAccountToken: false
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      ports:
        - name: http
          containerPort: 8000
      envFrom:
        - configMapRef:
            name: {{ include "maright-app.fullname" . }}
      readinessProbe:
        httpGet:
          path: /ready
          port: http
        periodSeconds: 5
      livenessProbe:
        httpGet:
          path: /health
          port: http
        initialDelaySeconds: 5
        periodSeconds: 10
      {{- if gt (int .Values.shutdown.preStopSleepSeconds) 0 }}
      lifecycle:
        preStop:
          sleep:
            seconds: {{ .Values.shutdown.preStopSleepSeconds }}
      {{- end }}
      resources:
        {{- toYaml .Values.resources | nindent 8 }}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
{{- end -}}

{{- define "maright-app.isCanary" -}}
{{- if and (ne .Values.workload "deployment") (eq .Values.rollout.strategy "canary") }}true{{ end -}}
{{- end -}}
