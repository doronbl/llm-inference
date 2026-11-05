# Rendered by scripts/60-router.sh (envsubst). Cell order defines cell indexes:
# append new cells at the end.
apiVersion: v1
kind: ConfigMap
metadata:
  name: router-settings
  namespace: llm-router
data:
  ROUTER_REGION: "${REGION}"
  ROUTER_COGNITO_ISSUER: "${COGNITO_ISSUER}"
  ROUTER_COGNITO_JWKS_URL: "${COGNITO_JWKS_URL}"
  ROUTER_REQUIRED_SCOPE: "${REQUIRED_SCOPE}"
  ROUTER_CELLS_FILE: /etc/router/cells.json
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: router-cells
  namespace: llm-router
data:
  cells.json: |
    ${CELLS_JSON}
