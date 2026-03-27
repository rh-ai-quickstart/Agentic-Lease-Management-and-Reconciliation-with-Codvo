{{/*
Expand the name of the chart.
*/}}
{{- define "neio-leasingops.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "neio-leasingops.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "neio-leasingops.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "neio-leasingops.labels" -}}
helm.sh/chart: {{ include "neio-leasingops.chart" . }}
{{ include "neio-leasingops.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: neio-leasingops
{{- end }}

{{/*
Selector labels
*/}}
{{- define "neio-leasingops.selectorLabels" -}}
app.kubernetes.io/name: {{ include "neio-leasingops.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "neio-leasingops.serviceAccountName" -}}
{{- $saCreate := false }}
{{- $saName := "" }}
{{- if .Values.serviceAccount }}
{{- $saCreate = .Values.serviceAccount.create }}
{{- $saName = .Values.serviceAccount.name }}
{{- else if and .Values.security .Values.security.serviceAccount }}
{{- $saCreate = .Values.security.serviceAccount.create }}
{{- $saName = .Values.security.serviceAccount.name }}
{{- end }}
{{- if $saCreate }}
{{- default (include "neio-leasingops.fullname" .) $saName }}
{{- else }}
{{- default "default" $saName }}
{{- end }}
{{- end }}

{{/*
Image pull secrets
*/}}
{{- define "neio-leasingops.imagePullSecrets" -}}
{{- if .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- range .Values.global.imagePullSecrets }}
  - name: {{ . }}
{{- end }}
{{- else if .Values.imagePullSecrets }}
imagePullSecrets:
{{- range .Values.imagePullSecrets }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end }}
