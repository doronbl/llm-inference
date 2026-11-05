# Rendered by scripts/60-router.sh (envsubst: ROUTER_IMAGE).
apiVersion: apps/v1
kind: Deployment
metadata:
  name: router
  namespace: llm-router
  labels:
    app.kubernetes.io/name: router
spec:
  replicas: 2
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app.kubernetes.io/name: router
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  template:
    metadata:
      labels:
        app.kubernetes.io/name: router
    spec:
      automountServiceAccountToken: false
      nodeSelector:
        llm-inference/node-class: system
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: router
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: router
      # Long SSE streams: the ALB target group drains for 300 s.
      terminationGracePeriodSeconds: 330
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: router
          image: ${ROUTER_IMAGE}
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
          envFrom:
            - configMapRef:
                name: router-settings
          volumeMounts:
            - name: cells
              mountPath: /etc/router
              readOnly: true
            - name: tmp
              mountPath: /tmp
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 10
            failureThreshold: 3
          lifecycle:
            preStop:
              sleep:
                seconds: 15
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              memory: 512Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
      volumes:
        - name: cells
          configMap:
            name: router-cells
        - name: tmp
          emptyDir: {}
