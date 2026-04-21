{{/*
Expand the name of the chart.
*/}}
{{- define "app-umbrella.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "app-umbrella.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "app-umbrella.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
