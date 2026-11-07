{{- define "uos.name" -}}{{ .Release.Name }}{{- end }}
{{- define "uos.labels" -}}
app.kubernetes.io/name: unifi-os-server
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
{{- define "uos.selector" -}}
app.kubernetes.io/name: unifi-os-server
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
{{- define "uos.image" -}}{{ .Values.localImage }}:{{ .Values.uos.version }}{{- end }}
{{- /* installers passed to fetch: the forced uos.arch only, or both for detection on the node */}}
{{- define "uos.installers" -}}
{{- $arches := list "amd64" "arm64" -}}
{{- if .Values.uos.arch -}}
{{- if not (has .Values.uos.arch $arches) }}{{ fail (printf "uos.arch must be \"\", amd64 or arm64, got %q" .Values.uos.arch) }}{{ end -}}
{{- $arches = list .Values.uos.arch -}}
{{- end -}}
{{- $out := dict -}}
{{- range $arches -}}
{{- $i := get $.Values.uos.installers . | default dict -}}
{{- if or (not $i) (not $i.url) (not $i.sha256) }}{{ fail (printf "uos.installers.%s needs url and sha256" .) }}{{ end -}}
{{- $_ := set $out . $i -}}
{{- end -}}
{{- toJson $out -}}
{{- end }}
