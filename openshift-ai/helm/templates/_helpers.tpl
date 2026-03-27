{{/*
Expand the name of the chart.
*/}}
{{- define "neio-openshift-ai.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
*/}}
{{- define "neio-openshift-ai.fullname" -}}
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
{{- define "neio-openshift-ai.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "neio-openshift-ai.labels" -}}
helm.sh/chart: {{ include "neio-openshift-ai.chart" . }}
{{ include "neio-openshift-ai.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: neio-openshift-ai
{{- end }}

{{/*
Selector labels
*/}}
{{- define "neio-openshift-ai.selectorLabels" -}}
app.kubernetes.io/name: {{ include "neio-openshift-ai.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "neio-openshift-ai.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "neio-openshift-ai.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Return the proper image name
*/}}
{{- define "neio-openshift-ai.image" -}}
{{- $registryName := .Values.global.imageRegistry -}}
{{- $repositoryName := .imageRepository -}}
{{- $tag := .imageTag | toString -}}
{{- printf "%s/%s:%s" $registryName $repositoryName $tag -}}
{{- end -}}

{{/*
Return the proper GPU resource configuration
*/}}
{{- define "neio-openshift-ai.gpuResources" -}}
{{- if .Values.vllm.resources }}
resources:
  requests:
    {{- if .Values.vllm.resources.requests.cpu }}
    cpu: {{ .Values.vllm.resources.requests.cpu }}
    {{- end }}
    {{- if .Values.vllm.resources.requests.memory }}
    memory: {{ .Values.vllm.resources.requests.memory }}
    {{- end }}
    {{- if index .Values.vllm.resources.requests "nvidia.com/gpu" }}
    nvidia.com/gpu: {{ index .Values.vllm.resources.requests "nvidia.com/gpu" }}
    {{- end }}
  limits:
    {{- if .Values.vllm.resources.limits.cpu }}
    cpu: {{ .Values.vllm.resources.limits.cpu }}
    {{- end }}
    {{- if .Values.vllm.resources.limits.memory }}
    memory: {{ .Values.vllm.resources.limits.memory }}
    {{- end }}
    {{- if index .Values.vllm.resources.limits "nvidia.com/gpu" }}
    nvidia.com/gpu: {{ index .Values.vllm.resources.limits "nvidia.com/gpu" }}
    {{- end }}
{{- end }}
{{- end -}}
