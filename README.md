# ArgoCD Datadog Kubernetes Autoscaling Example

A reference implementation demonstrating how to deploy **Datadog Kubernetes Autoscaling (DKA)** using **ArgoCD** and GitOps principles. This repository shows how to manage Datadog Operator, DatadogAgent, and application workloads with DatadogPodAutoscaler using the App of Apps pattern with sync waves for dependency management.

## Overview

This example replicates the [dka-terraform-example](https://github.com/kennonkwok/dka-terraform-example) using a GitOps approach. Instead of Terraform, we use ArgoCD to declaratively manage all Kubernetes resources, ensuring your cluster state matches what's defined in Git.

### What This Repository Demonstrates

- **App of Apps Pattern**: A root ArgoCD Application that manages child Applications
- **Sync Waves**: Ordered deployment ensuring dependencies are met (Operator → Agent → Workload)
- **Helm Integration**: Using both Helm charts from registries and Git-based charts
- **GitOps Best Practices**: Declarative configuration with automated sync and self-healing
- **Datadog Kubernetes Autoscaling**: Complete DKA setup with workload autoscaling enabled

## Architecture

The deployment is organized into three stages, each managed by a separate ArgoCD Application:

```
┌─────────────────────────────────────────────────────────────────┐
│                        Root Application                         │
│                    (argocd/root-app.yaml)                       │
│                                                                 │
│  Manages three child Applications using App of Apps pattern    │
└─────────────────────────────────────────────────────────────────┘
                               │
                               ├── Sync Wave 0 ──┐
                               │                  │
                               │                  ▼
┌──────────────────────────────────────────────────────────────────┐
│                  Stage 1: Datadog Operator                       │
│              (argocd/apps/datadog-operator.yaml)                 │
│                                                                  │
│  • Creates 'datadog' namespace                                   │
│  • Deploys Datadog Operator via Helm (v2.11.1)                   │
│  • Installs CRDs (DatadogAgent, DatadogPodAutoscaler)            │
│  • User creates datadog-secret manually before deployment        │
└──────────────────────────────────────────────────────────────────┘
                               │
                               ├── Sync Wave 1 ──┐
                               │                  │
                               │                  ▼
┌──────────────────────────────────────────────────────────────────┐
│                  Stage 2: DatadogAgent                           │
│              (argocd/apps/datadog-agent.yaml)                    │
│                                                                  │
│  • Deploys DatadogAgent CR (v2alpha1)                            │
│  • Enables workload autoscaling feature                          │
│  • References datadog-secret for API/app keys                    │
│  • Configures cluster agent with autoscaling parameters          │
└──────────────────────────────────────────────────────────────────┘
                               │
                               ├── Sync Wave 2 ──┐
                               │                  │
                               │                  ▼
┌──────────────────────────────────────────────────────────────────┐
│           Stage 3: NGINX Application + Autoscaler                │
│            (argocd/apps/nginx-dka-demo.yaml)                     │
│                                                                  │
│  • Creates 'nginx-dka-demo' namespace                            │
│  • Deploys NGINX Deployment (5 initial replicas)                 │
│  • Creates DatadogPodAutoscaler targeting NGINX                  │
│  • Configures CPU-based autoscaling (70% target)                 │
└──────────────────────────────────────────────────────────────────┘
```

### Dependency Management

Sync waves ensure proper ordering:
- **Wave -1**: Namespace creation (infrastructure)
- **Wave 0**: Datadog Operator deployment (provides CRDs)
- **Wave 1**: DatadogAgent deployment (uses operator CRDs)
- **Wave 2**: Application workloads (uses agent features)

## Repository Structure

```
dka-argocd-example/
├── README.md                           # This file
├── .gitignore                          # Prevents committing secrets
│
├── argocd/
│   ├── root-app.yaml                   # Root Application (App of Apps)
│   └── apps/
│       ├── datadog-operator.yaml       # Stage 1: Operator + namespace
│       ├── datadog-agent.yaml          # Stage 2: DatadogAgent CR
│       └── nginx-dka-demo.yaml         # Stage 3: Application (Helm)
│
├── manifests/
│   ├── stage1-operator/
│   │   ├── namespace.yaml              # Datadog namespace
│   │   └── secret.yaml.example         # Secret template (copy to secret.yaml)
│   └── stage2-agent/
│       └── datadog-agent.yaml          # DatadogAgent CR with autoscaling
│
└── charts/
    └── nginx-dka-demo/                 # Helm chart for demo application
        ├── Chart.yaml                  # Chart metadata
        ├── values.yaml                 # Configurable parameters
        └── templates/
            ├── namespace.yaml          # Application namespace
            ├── deployment.yaml         # NGINX deployment
            └── pod-autoscaler.yaml     # DatadogPodAutoscaler CR
```

## Prerequisites

To deploy this example, you need:

1. **Kubernetes Cluster**: v1.20+ (minikube, kind, GKE, EKS, AKS, etc.)
2. **ArgoCD**: Installed in your cluster ([installation guide](https://argo-cd.readthedocs.io/en/stable/getting_started/))
3. **kubectl**: Configured to access your cluster
4. **Datadog Account**: With API and Application keys ([sign up](https://www.datadoghq.com/))

## How to Use This Repository

### Option 1: Use as a Reference

This repository is designed as a **reference implementation**. Study the files to understand:
- How to structure ArgoCD Applications with sync waves
- How to integrate Helm charts with ArgoCD
- How to configure Datadog Kubernetes Autoscaling
- How to implement the App of Apps pattern

Adapt the patterns to your own repository and requirements.

### Option 2: Deploy to Your Cluster

If you want to test this example directly:

#### Step 1: Create the Datadog Secret

Before deploying anything, create the Datadog secret manually:

```bash
# Option A: Copy and edit the example file
cp manifests/stage1-operator/secret.yaml.example manifests/stage1-operator/secret.yaml
# Edit secret.yaml with your actual Datadog API and App keys
kubectl apply -f manifests/stage1-operator/secret.yaml

# Option B: Create directly with kubectl
kubectl create namespace datadog
kubectl create secret generic datadog-secret \
  -n datadog \
  --from-literal=api-key=YOUR_DATADOG_API_KEY \
  --from-literal=app-key=YOUR_DATADOG_APP_KEY
```

Get your keys from:
- API Key: https://app.datadoghq.com/organization-settings/api-keys
- App Key: https://app.datadoghq.com/organization-settings/application-keys

#### Step 2: Fork and Customize

1. Fork this repository to your GitHub account
2. Update `repoURL` in all Application manifests to point to your fork:
   - `argocd/root-app.yaml`
   - `argocd/apps/datadog-operator.yaml`
   - `argocd/apps/datadog-agent.yaml`
   - `argocd/apps/nginx-dka-demo.yaml`

3. Optionally customize:
   - Cluster name in `manifests/stage2-agent/datadog-agent.yaml`
   - Datadog site (datadoghq.com, datadoghq.eu, etc.)
   - Autoscaling parameters in `charts/nginx-dka-demo/values.yaml`

#### Step 3: Deploy the Root Application

```bash
# Apply the root Application
kubectl apply -f argocd/root-app.yaml

# Watch the deployment
kubectl get applications -n argocd
```

ArgoCD will automatically:
1. Create the three child Applications
2. Deploy them in order based on sync waves
3. Monitor and sync changes from Git

#### Step 4: Verify the Deployment

```bash
# Check Datadog Operator
kubectl get pods -n datadog
kubectl get datadogagent -n datadog

# Check NGINX application
kubectl get deployment -n nginx-dka-demo
kubectl get datadogpodautoscaler -n nginx-dka-demo

# View autoscaler details
kubectl describe datadogpodautoscaler nginx-dka-demo-dpa -n nginx-dka-demo
```

#### Step 5: View in ArgoCD UI

Access the ArgoCD UI to see the Application tree:

```bash
# Get ArgoCD admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Port forward to access UI
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Open browser to https://localhost:8080
# Username: admin
# Password: (from command above)
```

## Key Concepts

### App of Apps Pattern

The root Application (`argocd/root-app.yaml`) points to a directory containing other Application manifests (`argocd/apps/`). This creates a hierarchy where the root manages children, enabling:
- Centralized management of multiple applications
- Consistent sync policies across applications
- Easy addition of new applications

### Sync Waves

Sync waves control deployment order using annotations:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "0"  # Lower numbers deploy first
```

This ensures:
- Namespaces exist before resources that use them
- CRDs are installed before custom resources that use them
- Dependencies are met before dependent resources deploy

### Helm Integration in ArgoCD

ArgoCD supports multiple ways to use Helm:

1. **Helm Chart from Registry** (Stage 1):
   ```yaml
   source:
     repoURL: https://helm.datadoghq.com
     chart: datadog-operator
     targetRevision: 2.11.1
   ```

2. **Helm Chart from Git** (Stage 3):
   ```yaml
   source:
     repoURL: https://github.com/user/repo.git
     path: charts/nginx-dka-demo
   ```

3. **Multiple Sources** (Stage 1):
   Combine Helm chart from registry with additional Git manifests.

### Secrets Management

This example uses **manual secret creation** for simplicity. For production, consider:
- **Sealed Secrets**: Encrypt secrets in Git
- **External Secrets Operator**: Sync from external secret stores (AWS Secrets Manager, HashiCorp Vault, etc.)
- **SOPS**: Encrypt secrets with age or PGP

### Datadog Kubernetes Autoscaling

The DatadogPodAutoscaler provides intelligent autoscaling based on:
- Real-time metrics from Datadog
- Predictive algorithms (not just reactive)
- Configurable scale-up/down policies
- Integration with Datadog APM and RUM data

Configuration highlights:

```yaml
# Scale up by 50% every 2 minutes when needed
upscale:
  type: Percent
  value: 50
  periodSeconds: 120

# Scale down by 20% every 20 minutes when possible
downscale:
  type: Percent
  value: 20
  periodSeconds: 1200

# Target 70% CPU utilization
objectives:
  - type: cpu
    value: 70
```

## Customization

### Adjusting Autoscaling Behavior

Edit `charts/nginx-dka-demo/values.yaml`:

```yaml
autoscaler:
  minReplicas: 3        # Minimum pod count
  maxReplicas: 100      # Maximum pod count
  targetCPUUtilization: 70  # Target CPU percentage
  scaleUp:
    percentIncrease: 50     # Scale-up aggressiveness
    periodSeconds: 120      # Scale-up cooldown
  scaleDown:
    percentDecrease: 20     # Scale-down aggressiveness
    periodSeconds: 1200     # Scale-down cooldown
```

### Using Different Metrics

Modify the `objectives` in `pod-autoscaler.yaml`:

```yaml
objectives:
  # CPU-based
  - type: cpu
    source: Datadog
    value: 70

  # Memory-based
  - type: memory
    source: Datadog
    value: 80

  # Custom Datadog metric
  - type: DatadogMetric
    source: Datadog
    value: 100
    metric:
      query: "avg:trace.web.request.duration{service:nginx}"
```

### Adding More Applications

Create a new Application manifest in `argocd/apps/` with the appropriate sync wave:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  # ... application configuration
```

The root Application will automatically manage it.

## Troubleshooting

### Operator Pod Not Starting

```bash
# Check operator logs
kubectl logs -n datadog -l app.kubernetes.io/name=datadog-operator

# Verify CRDs are installed
kubectl get crd | grep datadog
```

### DatadogAgent Not Creating Pods

```bash
# Check DatadogAgent status
kubectl get datadogagent -n datadog -o yaml

# Check operator logs for errors
kubectl logs -n datadog -l app.kubernetes.io/name=datadog-operator
```

### Secret Not Found

```bash
# Verify secret exists
kubectl get secret datadog-secret -n datadog

# Check secret has correct keys
kubectl get secret datadog-secret -n datadog -o jsonpath='{.data}' | jq
```

### Application Not Syncing

```bash
# Check Application status
kubectl get application -n argocd

# Describe Application for events
kubectl describe application <app-name> -n argocd

# View ArgoCD controller logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller
```

### DatadogPodAutoscaler Not Scaling

```bash
# Check autoscaler status
kubectl describe datadogpodautoscaler -n nginx-dka-demo

# Check cluster agent logs
kubectl logs -n datadog -l app=datadog-cluster-agent

# Verify workload autoscaling is enabled
kubectl get datadogagent -n datadog -o jsonpath='{.spec.features.workloadAutoscaling.enabled}'
```

## Additional Resources

- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [Datadog Kubernetes Autoscaling](https://docs.datadoghq.com/containers/kubernetes/autoscaling/)
- [Datadog Operator](https://github.com/DataDog/datadog-operator)
- [DatadogAgent CRD Reference](https://docs.datadoghq.com/containers/kubernetes/installation/?tab=datadogoperator)
- [Original Terraform Example](https://github.com/kennonkwok/dka-terraform-example)

## License

This is an example/reference repository intended for educational purposes.

## Contributing

This is a personal reference repository. Feel free to fork and adapt to your needs.
