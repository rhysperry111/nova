apiVersion: v1
kind: ConfigMap

metadata:
  name: tempo-grafana-datasource
  namespace: ${namespace}
  labels:
    grafana_datasource: "1"

data:
  datasource.yaml: |-
    apiVersion: 1
    datasources:
      - access: proxy
        editable: false
        isDefault: false
        name: Tempo
        orgId: 1
        type: tempo
        url: http://tempo.${namespace}.svc.cluster.local:3200
        version: 2
