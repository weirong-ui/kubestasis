{{/* 通用命名与标签 */}}

{{- define "kubestasis.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "kubestasis.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "kubestasis.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "kubestasis.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride -}}
{{- end -}}

{{- define "kubestasis.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "kubestasis.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/* Pod 选择器标签：必须稳定，不能包含 version（升级会改它导致 selector 不可变） */}}
{{- define "kubestasis.selectorLabels" -}}
control-plane: controller-manager
app.kubernetes.io/name: {{ include "kubestasis.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "kubestasis.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "kubestasis.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "kubestasis.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) -}}
{{- end -}}

{{- define "kubestasis.webhookServiceName" -}}
{{- printf "%s-webhook" (include "kubestasis.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* 自签证书开关：开了 webhook 又没开 cert-manager 时由 chart 现场生成 */}}
{{- define "kubestasis.selfSignedCerts" -}}
{{- if and .Values.webhook.enabled (not .Values.webhook.certManager.enabled) -}}true{{- end -}}
{{- end -}}

{{/* 多副本：反亲和默认值的开关 */}}
{{- define "kubestasis.multiReplica" -}}
{{- if gt (int .Values.replicaCount) 1 -}}true{{- end -}}
{{- end -}}

{{/* PDB 开关：多副本且没被显式关掉。
     不能用 `| default true` 判断——Helm 的 default 把 false 也当空值，
     --set podDisruptionBudget.enabled=false 会被吞掉，PDB 照样渲染。 */}}
{{- define "kubestasis.pdbEnabled" -}}
{{- if and (gt (int .Values.replicaCount) 1) (ne (toString .Values.podDisruptionBudget.enabled) "false") -}}true{{- end -}}
{{- end -}}
