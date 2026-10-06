{{/*
Names, labels and shared snippets. The helpers are prefixed "connector." (not the chart name) so that the
three connector charts stay identical apart from Chart.yaml and image.repository.
*/}}

{{/* Release = Deployment = Service = ServiceAccount name: <AppName>-<AppInstance> (ADR-0003). */}}
{{- define "connector.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "connector.configMapName" -}}
{{- printf "%s-config" (include "connector.fullname" .) -}}
{{- end -}}

{{/* The Secret mounted at /secrets/: never templated from values (ADR-0013); created by the deployer or ESO. */}}
{{- define "connector.secretName" -}}
{{- .Values.secrets.existingSecret | default (printf "%s-secrets" (include "connector.fullname" .)) -}}
{{- end -}}

{{- define "connector.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- include "connector.fullname" . -}}
{{- else -}}
{{- .Values.serviceAccount.name | default "default" -}}
{{- end -}}
{{- end -}}

{{/* repository:tag, or repository@digest when image.digest pins it (ADR-0010). */}}
{{- define "connector.image" -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository (required "image.tag is required: the deployer passes --set-string image.tag=<tag>" .Values.image.tag) -}}
{{- end -}}
{{- end -}}

{{/* The expected identity tuple <env>/<flow>/<AppName>/<AppInstance> (ADR-0003). */}}
{{- define "connector.tuple" -}}
{{- with .Values.identity -}}
{{- printf "%s/%s/%s/%s" .env .flow .app .instance -}}
{{- end -}}
{{- end -}}

{{/*
Selector labels of the connector pods. app.kubernetes.io/component keeps the helm test pod (same name and
instance labels, component smoke-test) out of the Service endpoints and the ReplicaSet selector.
*/}}
{{- define "connector.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: connector
{{- end -}}

{{/*
Labels every object carries besides its component (ADR-0003). The identity labels are <labelDomain>/<name>: the
deployer passes the domain, projects[0].group of platform.yml reversed (ADR-0041).
*/}}
{{- define "connector.commonLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: github-cicd-simple-apps
app.kubernetes.io/version: {{ splitList "@" (toString .Values.image.tag) | first | trunc 63 | trimAll "-_." | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- $domain := required "labelDomain is required: the deployer passes --set-string labelDomain=<domain>, projects[0].group of platform.yml reversed (ADR-0041)" .Values.labelDomain }}
{{ $domain }}/env: {{ .Values.identity.env | quote }}
{{ $domain }}/flow: {{ .Values.identity.flow | quote }}
{{ $domain }}/app: {{ .Values.identity.app | quote }}
{{ $domain }}/instance: {{ .Values.identity.instance | quote }}
{{- end -}}

{{- define "connector.labels" -}}
{{ include "connector.commonLabels" . }}
app.kubernetes.io/component: connector
{{- end -}}

{{/*
Render-time guards: the chart belongs to identity.app, and the identity variables in env restate the
identity (config-lint check 4 compares both with the config-tree path).
*/}}
{{- define "connector.validate" -}}
{{- $id := .Values.identity -}}
{{- if ne $id.app .Chart.Name -}}
{{- fail (printf "identity.app is %q but this is the %s chart" $id.app .Chart.Name) -}}
{{- end -}}
{{- $expected := dict "APP_ENV" $id.env "APP_FLOW" $id.flow "APP_NAME" $id.app "APP_INSTANCE" $id.instance -}}
{{- range $name, $want := $expected -}}
{{- if hasKey $.Values.env $name -}}
{{- $got := toString (index $.Values.env $name) -}}
{{- if ne $got $want -}}
{{- fail (printf "env.%s is %q but identity says %q: both must restate the config-tree path" $name $got $want) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- range $layer, $files := .Values.appFiles -}}
{{- range $name, $content := $files -}}
{{- if eq $name "application.yml" -}}
{{- fail (printf "appFiles.%s.application.yml: the application.yml layers are appConfig.%s" $layer $layer) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
One ConfigMap data entry: a literal block when the text survives one unchanged (the rendered ConfigMap stays
readable in diffs), else a double-quoted string. Argument: (list key content).
*/}}
{{- define "connector.dataEntry" -}}
{{- $key := index . 0 -}}
{{- $text := toString (index . 1) -}}
{{- if or (eq $text "") (regexMatch "^\\n*[ \\t]|^\\n+$|[\\x00-\\x08\\x0b-\\x1f\\x7f\\x{85}\\x{2028}\\x{2029}\\x{feff}]" $text) -}}
{{ $key | quote }}: {{ $text | quote }}
{{- else -}}
{{ $key | quote }}: |{{ if hasSuffix "\n\n" $text }}+{{ else if not (hasSuffix "\n" $text) }}-{{ end }}
{{ trimSuffix "\n" $text | indent 2 }}
{{- end -}}
{{- end -}}

{{/* ConfigMap keys in mount order: [key, path] for every layer file present (ADR-0011). */}}
{{- define "connector.configItems" -}}
{{- $items := list -}}
{{- range $layer := list "flow" "common" "instance" -}}
{{- if hasKey $.Values.appConfig $layer -}}
{{- $items = append $items (list (printf "%s.application.yml" $layer) (printf "%s/application.yml" $layer)) -}}
{{- end -}}
{{- range $name, $content := (get $.Values.appFiles $layer | default dict) -}}
{{- $items = append $items (list (printf "%s.%s" $layer $name) (printf "%s/%s" $layer $name)) -}}
{{- end -}}
{{- end -}}
{{- toJson $items -}}
{{- end -}}
