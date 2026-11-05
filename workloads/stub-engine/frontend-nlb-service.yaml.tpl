# Internal NLB in front of the Dynamo frontend of this cell, created by the AWS
# Load Balancer Controller (IP targets, cell subnet only). The regional router
# reaches it at http://<nlb-dns-name>:8000.
# Rendered per cell by scripts/50-stub-engine.sh (envsubst).
apiVersion: v1
kind: Service
metadata:
  name: frontend-nlb
  namespace: llm-inference
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-scheme: internal
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    service.beta.kubernetes.io/aws-load-balancer-subnets: ${CELL_SUBNET_ID}
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol: HTTP
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-path: /health
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-port: traffic-port
    # Long SSE streams.
    service.beta.kubernetes.io/aws-load-balancer-listener-attributes.TCP-8000: tcp.idle_timeout.seconds=3600
    service.beta.kubernetes.io/aws-load-balancer-target-group-attributes: deregistration_delay.timeout_seconds=300
    service.beta.kubernetes.io/aws-load-balancer-additional-resource-tags: llm-inference/cell=${CELL_ID}
spec:
  type: LoadBalancer
  loadBalancerClass: service.k8s.aws/nlb
  # Only clients inside the Region VPC (the regional router pods).
  loadBalancerSourceRanges:
    - ${VPC_CIDR}
  selector:
    nvidia.com/dynamo-graph-deployment-name: stub-engine
    nvidia.com/dynamo-component-type: frontend
  ports:
    - name: http
      port: 8000
      targetPort: 8000
      protocol: TCP
