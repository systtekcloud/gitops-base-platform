{{- define "cloudframe-platform.vaultDefaultNamespace" -}}
{{- default .Release.Namespace .Values.vaultResources.defaultNamespace -}}
{{- end -}}

{{- define "cloudframe-platform.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}
