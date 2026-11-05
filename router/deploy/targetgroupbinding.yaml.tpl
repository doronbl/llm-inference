# Rendered by scripts/60-router.sh (envsubst: ROUTER_TARGET_GROUP_ARN).
# The ALB, listener and target group are owned by Terraform (infra/modules/edge);
# the AWS Load Balancer Controller only registers router pod IPs.
# The ALB -> pod security group rule is also owned by Terraform, so the
# controller does not manage networking for this binding.
apiVersion: elbv2.k8s.aws/v1beta1
kind: TargetGroupBinding
metadata:
  name: router
  namespace: llm-router
spec:
  targetGroupARN: ${ROUTER_TARGET_GROUP_ARN}
  targetType: ip
  serviceRef:
    name: router
    port: 8080
