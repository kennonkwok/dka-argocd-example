#!/usr/bin/env bash

################################################################################
# Datadog Kubernetes Autoscaling (DKA) - Minikube Deployment Script
#
# This script automates the complete deployment of the DKA demo on minikube:
# - Creates/manages minikube cluster
# - Installs ArgoCD
# - Creates Datadog secrets
# - Deploys ArgoCD root application
# - Monitors wave-based deployment (Operator → Agent → NGINX)
# - Verifies complete deployment
#
# Prerequisites:
# - minikube, kubectl, curl/wget installed
# - Docker (or chosen driver) running
# - DD_API_KEY and DD_APP_KEY environment variables set
#
# Usage:
#   export DD_API_KEY=xxx DD_APP_KEY=yyy
#   ./scripts/deploy-minikube.sh [options]
#
# Options:
#   --profile PROFILE       Minikube profile name (default: dka-demo)
#   --cpus CPUS            CPU allocation (default: 4)
#   --memory MEMORY        Memory in MB (default: 8192)
#   --driver DRIVER        Minikube driver (default: docker)
#   --repo-url URL         Override repository URL (for forks)
#   --cleanup-on-error     Auto-cleanup on failure
#   --skip-verify          Skip post-deployment verification
#   -h, --help             Show this help message
#
################################################################################

set -euo pipefail

################################################################################
# Global Variables
################################################################################

# Default configuration
MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-dka-demo}"
MINIKUBE_CPUS="${MINIKUBE_CPUS:-4}"
MINIKUBE_MEMORY="${MINIKUBE_MEMORY:-8192}"
MINIKUBE_DRIVER="${MINIKUBE_DRIVER:-docker}"
REPO_URL="${REPO_URL:-}"
CLEANUP_ON_ERROR="${CLEANUP_ON_ERROR:-false}"
SKIP_VERIFY="${SKIP_VERIFY:-false}"

# Deployment tracking
CURRENT_STAGE="initialization"
ARGOCD_PASSWORD=""

# Timeout values (seconds)
TIMEOUT_CLUSTER_READY=300
TIMEOUT_ARGOCD_READY=600
TIMEOUT_APP_SYNC=600
TIMEOUT_TOTAL=1800

# Poll interval
POLL_INTERVAL=10

# Exit codes
EXIT_MISSING_COMMAND=1
EXIT_MISSING_ENV_VAR=2
EXIT_INVALID_VALUE=3
EXIT_CLUSTER_CREATION_FAILED=10
EXIT_CLUSTER_START_FAILED=11
EXIT_CLUSTER_TIMEOUT=12
EXIT_ARGOCD_INSTALL_FAILED=20
EXIT_ARGOCD_TIMEOUT=21
EXIT_SECRET_CREATION_FAILED=30
EXIT_APP_DEPLOYMENT_FAILED=40
EXIT_APP_SYNC_FAILED=41
EXIT_APP_HEALTH_FAILED=42
EXIT_VERIFICATION_FAILED=50

################################################################################
# Color Codes for Logging
################################################################################

if [[ -t 1 ]]; then
    COLOR_RESET='\033[0m'
    COLOR_RED='\033[0;31m'
    COLOR_GREEN='\033[0;32m'
    COLOR_YELLOW='\033[0;33m'
    COLOR_BLUE='\033[0;34m'
    COLOR_CYAN='\033[0;36m'
    COLOR_BOLD='\033[1m'
else
    COLOR_RESET=''
    COLOR_RED=''
    COLOR_GREEN=''
    COLOR_YELLOW=''
    COLOR_BLUE=''
    COLOR_CYAN=''
    COLOR_BOLD=''
fi

################################################################################
# Logging Functions
################################################################################

log_info() {
    echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"
}

log_success() {
    echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $*"
}

log_error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2
}

log_warning() {
    echo -e "${COLOR_YELLOW}[WARNING]${COLOR_RESET} $*"
}

log_step() {
    echo ""
    echo -e "${COLOR_CYAN}${COLOR_BOLD}===================================================================${COLOR_RESET}"
    echo -e "${COLOR_CYAN}${COLOR_BOLD} $*${COLOR_RESET}"
    echo -e "${COLOR_CYAN}${COLOR_BOLD}===================================================================${COLOR_RESET}"
    echo ""
}

################################################################################
# Utility Functions
################################################################################

show_help() {
    cat << EOF
Datadog Kubernetes Autoscaling (DKA) - Minikube Deployment Script

Usage:
    export DD_API_KEY=xxx DD_APP_KEY=yyy
    $0 [options]

Options:
    --profile PROFILE       Minikube profile name (default: dka-demo)
    --cpus CPUS            CPU allocation (default: 4)
    --memory MEMORY        Memory in MB (default: 8192)
    --driver DRIVER        Minikube driver (default: docker)
    --repo-url URL         Override repository URL (for forks)
    --cleanup-on-error     Auto-cleanup on failure
    --skip-verify          Skip post-deployment verification
    -h, --help             Show this help message

Examples:
    # Basic deployment
    $0

    # Custom resources
    $0 --cpus 8 --memory 16384

    # Different profile
    $0 --profile my-cluster

    # Fork with custom repo URL
    $0 --repo-url https://github.com/myuser/dka-argocd-example.git

Prerequisites:
    - minikube installed
    - kubectl installed
    - curl or wget installed
    - Docker (or chosen driver) running
    - DD_API_KEY environment variable set
    - DD_APP_KEY environment variable set

EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --profile)
                MINIKUBE_PROFILE="$2"
                shift 2
                ;;
            --cpus)
                MINIKUBE_CPUS="$2"
                shift 2
                ;;
            --memory)
                MINIKUBE_MEMORY="$2"
                shift 2
                ;;
            --driver)
                MINIKUBE_DRIVER="$2"
                shift 2
                ;;
            --repo-url)
                REPO_URL="$2"
                shift 2
                ;;
            --cleanup-on-error)
                CLEANUP_ON_ERROR=true
                shift
                ;;
            --skip-verify)
                SKIP_VERIFY=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

prompt_yes_no() {
    local prompt="$1"
    local default="${2:-n}"

    if [[ "$default" == "y" ]]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi

    read -r -p "$prompt" response
    response=${response:-$default}

    case "$response" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

wait_for_condition() {
    local description="$1"
    local check_command="$2"
    local timeout="$3"
    local interval="${4:-$POLL_INTERVAL}"

    log_info "Waiting for: $description (timeout: ${timeout}s)"

    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if eval "$check_command" >/dev/null 2>&1; then
            log_success "$description (${elapsed}s elapsed)"
            return 0
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))

        if [[ $((elapsed % 60)) -eq 0 ]]; then
            log_info "Still waiting for: $description (${elapsed}s elapsed)"
        fi
    done

    log_error "Timeout waiting for: $description (${timeout}s elapsed)"
    return 1
}

retry_command() {
    local max_attempts="${1}"
    local delay="${2}"
    shift 2
    local command=("$@")

    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        if "${command[@]}"; then
            return 0
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            log_warning "Command failed (attempt $attempt/$max_attempts), retrying in ${delay}s..."
            sleep "$delay"
            delay=$((delay * 2))  # Exponential backoff
        fi

        attempt=$((attempt + 1))
    done

    log_error "Command failed after $max_attempts attempts"
    return 1
}

################################################################################
# Prerequisites Check
################################################################################

check_command() {
    local cmd="$1"
    local install_hint="$2"

    if ! command -v "$cmd" &> /dev/null; then
        log_error "Required command not found: $cmd"
        if [[ -n "$install_hint" ]]; then
            log_info "Installation: $install_hint"
        fi
        return 1
    fi

    log_success "Found: $cmd"
    return 0
}

check_prerequisites() {
    log_step "Step 1: Prerequisites Check"

    local missing_commands=false

    # Check required commands
    check_command "minikube" "https://minikube.sigs.k8s.io/docs/start/" || missing_commands=true
    check_command "kubectl" "https://kubernetes.io/docs/tasks/tools/" || missing_commands=true

    # Check for curl or wget
    if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then
        log_error "Required command not found: curl or wget"
        missing_commands=true
    else
        log_success "Found: curl or wget"
    fi

    check_command "git" "https://git-scm.com/downloads" || missing_commands=true

    if [[ "$missing_commands" == "true" ]]; then
        log_error "Missing required commands. Please install them and try again."
        exit $EXIT_MISSING_COMMAND
    fi

    # Check environment variables
    log_info "Checking environment variables..."

    if [[ -z "${DD_API_KEY:-}" ]]; then
        log_error "DD_API_KEY environment variable is not set"
        log_info "Please set it with: export DD_API_KEY=your-api-key"
        exit $EXIT_MISSING_ENV_VAR
    fi

    if [[ -z "${DD_APP_KEY:-}" ]]; then
        log_error "DD_APP_KEY environment variable is not set"
        log_info "Please set it with: export DD_APP_KEY=your-app-key"
        exit $EXIT_MISSING_ENV_VAR
    fi

    # Check for placeholder values
    if [[ "$DD_API_KEY" =~ ^(xxx|your-key|placeholder|REPLACE)$ ]] || [[ ${#DD_API_KEY} -lt 10 ]]; then
        log_warning "DD_API_KEY appears to be a placeholder value"
        if ! prompt_yes_no "Continue anyway?"; then
            log_info "Exiting. Please set a valid DD_API_KEY."
            exit $EXIT_INVALID_VALUE
        fi
    fi

    if [[ "$DD_APP_KEY" =~ ^(yyy|your-key|placeholder|REPLACE)$ ]] || [[ ${#DD_APP_KEY} -lt 10 ]]; then
        log_warning "DD_APP_KEY appears to be a placeholder value"
        if ! prompt_yes_no "Continue anyway?"; then
            log_info "Exiting. Please set a valid DD_APP_KEY."
            exit $EXIT_INVALID_VALUE
        fi
    fi

    log_success "DD_API_KEY is set (${#DD_API_KEY} characters)"
    log_success "DD_APP_KEY is set (${#DD_APP_KEY} characters)"

    # Display configuration summary
    echo ""
    log_info "Configuration Summary:"
    echo "  Minikube Profile: $MINIKUBE_PROFILE"
    echo "  CPUs: $MINIKUBE_CPUS"
    echo "  Memory: ${MINIKUBE_MEMORY}MB"
    echo "  Driver: $MINIKUBE_DRIVER"
    echo "  Repository URL: ${REPO_URL:-<auto-detect>}"
    echo "  Cleanup on Error: $CLEANUP_ON_ERROR"
    echo ""

    log_success "All prerequisites met"
}

################################################################################
# Repository URL Detection
################################################################################

detect_repo_url() {
    if [[ -n "$REPO_URL" ]]; then
        log_info "Using provided repository URL: $REPO_URL"
        return 0
    fi

    # Try to detect from git remote
    if [[ -d .git ]]; then
        local remote_url
        remote_url=$(git remote get-url origin 2>/dev/null || echo "")

        if [[ -n "$remote_url" ]]; then
            # Convert SSH to HTTPS if needed
            if [[ "$remote_url" =~ ^git@github\.com:(.+)$ ]]; then
                REPO_URL="https://github.com/${BASH_REMATCH[1]}"
            elif [[ "$remote_url" =~ ^https?:// ]]; then
                REPO_URL="$remote_url"
            fi

            # Remove .git suffix if present
            REPO_URL="${REPO_URL%.git}"

            log_info "Detected repository URL: $REPO_URL"
        fi
    fi

    # Default to the original repository
    if [[ -z "$REPO_URL" ]]; then
        REPO_URL="https://github.com/kennonkwok/dka-argocd-example"
        log_info "Using default repository URL: $REPO_URL"
    fi
}

################################################################################
# Minikube Cluster Management
################################################################################

check_minikube_status() {
    local status
    status=$(minikube status -p "$MINIKUBE_PROFILE" -o json 2>/dev/null || echo "{}")

    local host_status
    host_status=$(echo "$status" | grep -o '"Host":"[^"]*"' | cut -d'"' -f4 || echo "")

    echo "$host_status"
}

create_or_start_minikube() {
    log_step "Step 2: Minikube Cluster Management"

    CURRENT_STAGE="minikube_cluster"

    local cluster_status
    cluster_status=$(check_minikube_status)

    if [[ "$cluster_status" == "Running" ]]; then
        log_success "Minikube cluster '$MINIKUBE_PROFILE' is already running"
        log_info "Reusing existing cluster"

        # Configure kubectl context
        log_info "Configuring kubectl context..."
        minikube update-context -p "$MINIKUBE_PROFILE"

        return 0
    elif [[ "$cluster_status" == "Stopped" ]]; then
        log_info "Minikube cluster '$MINIKUBE_PROFILE' exists but is stopped"
        log_info "Starting cluster..."

        if ! minikube start -p "$MINIKUBE_PROFILE"; then
            log_error "Failed to start minikube cluster"
            exit $EXIT_CLUSTER_START_FAILED
        fi

        log_success "Cluster started"
    else
        log_info "Creating new minikube cluster: $MINIKUBE_PROFILE"
        log_info "Configuration: ${MINIKUBE_CPUS} CPUs, ${MINIKUBE_MEMORY}MB RAM, driver: $MINIKUBE_DRIVER"

        if ! minikube start \
            -p "$MINIKUBE_PROFILE" \
            --cpus="$MINIKUBE_CPUS" \
            --memory="$MINIKUBE_MEMORY" \
            --driver="$MINIKUBE_DRIVER"; then
            log_error "Failed to create minikube cluster"
            log_info "Troubleshooting:"
            log_info "  1. Check that Docker (or your chosen driver) is running"
            log_info "  2. Try a different driver with --driver flag"
            log_info "  3. Check minikube logs: minikube logs -p $MINIKUBE_PROFILE"
            exit $EXIT_CLUSTER_CREATION_FAILED
        fi

        log_success "Cluster created"
    fi

    # Wait for cluster to be ready
    log_info "Waiting for cluster to be fully ready..."
    if ! wait_for_condition \
        "Cluster ready" \
        "kubectl cluster-info >/dev/null 2>&1" \
        "$TIMEOUT_CLUSTER_READY"; then
        log_error "Cluster failed to become ready"
        log_info "Check status: minikube status -p $MINIKUBE_PROFILE"
        exit $EXIT_CLUSTER_TIMEOUT
    fi

    # Display cluster info
    log_info "Cluster information:"
    kubectl cluster-info | head -n 2

    log_success "Minikube cluster is ready"
}

################################################################################
# ArgoCD Installation
################################################################################

install_argocd() {
    log_step "Step 3: ArgoCD Installation"

    CURRENT_STAGE="argocd_installation"

    # Check if ArgoCD namespace already exists
    if kubectl get namespace argocd >/dev/null 2>&1; then
        log_warning "ArgoCD namespace already exists"

        # Check if ArgoCD is already installed
        if kubectl get deployment argocd-server -n argocd >/dev/null 2>&1; then
            log_info "ArgoCD appears to be already installed"
            if ! prompt_yes_no "Reinstall ArgoCD?" "n"; then
                log_info "Skipping ArgoCD installation"

                # Still need to retrieve password
                retrieve_argocd_password
                return 0
            fi

            log_info "Deleting existing ArgoCD installation..."
            kubectl delete namespace argocd --timeout=120s || true
            sleep 5
        fi
    fi

    # Create namespace
    log_info "Creating argocd namespace..."
    kubectl create namespace argocd

    # Install ArgoCD
    log_info "Installing ArgoCD from official manifest..."
    local argocd_manifest="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"

    if command -v curl &> /dev/null; then
        if ! curl -sSL "$argocd_manifest" | kubectl apply -n argocd -f -; then
            log_error "Failed to install ArgoCD"
            exit $EXIT_ARGOCD_INSTALL_FAILED
        fi
    else
        if ! wget -qO- "$argocd_manifest" | kubectl apply -n argocd -f -; then
            log_error "Failed to install ArgoCD"
            exit $EXIT_ARGOCD_INSTALL_FAILED
        fi
    fi

    log_success "ArgoCD manifests applied"

    # Wait for ArgoCD components to be ready
    log_info "Waiting for ArgoCD components to be ready..."

    local components=(
        "deployment/argocd-server"
        "deployment/argocd-repo-server"
        "deployment/argocd-applicationset-controller"
        "statefulset/argocd-application-controller"
    )

    for component in "${components[@]}"; do
        log_info "Waiting for $component..."
        if ! kubectl wait "$component" \
            --for=condition=Available \
            --timeout="${TIMEOUT_ARGOCD_READY}s" \
            -n argocd 2>/dev/null; then
            # StatefulSet doesn't have Available condition, check Ready instead
            if [[ "$component" == statefulset/* ]]; then
                if ! kubectl rollout status "$component" -n argocd --timeout="${TIMEOUT_ARGOCD_READY}s"; then
                    log_error "Timeout waiting for $component"
                    log_info "Check pod status: kubectl get pods -n argocd"
                    exit $EXIT_ARGOCD_TIMEOUT
                fi
            else
                log_error "Timeout waiting for $component"
                log_info "Check pod status: kubectl get pods -n argocd"
                exit $EXIT_ARGOCD_TIMEOUT
            fi
        fi
        log_success "$component is ready"
    done

    log_success "All ArgoCD components are ready"

    # Retrieve admin password
    retrieve_argocd_password

    # Display access information
    echo ""
    log_info "ArgoCD Access Information:"
    echo "  UI URL: https://localhost:8080"
    echo "  Username: admin"
    echo "  Password: $ARGOCD_PASSWORD"
    echo ""
    log_info "To access ArgoCD UI, run in another terminal:"
    echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
    echo ""
}

retrieve_argocd_password() {
    log_info "Retrieving ArgoCD admin password..."

    # Wait for secret to exist
    if ! wait_for_condition \
        "ArgoCD initial admin secret exists" \
        "kubectl get secret argocd-initial-admin-secret -n argocd" \
        60; then
        log_warning "Could not retrieve ArgoCD admin password from secret"
        ARGOCD_PASSWORD="<check manually: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d>"
        return
    fi

    ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

    if [[ -z "$ARGOCD_PASSWORD" ]]; then
        log_warning "Retrieved password is empty"
        ARGOCD_PASSWORD="<check manually>"
    else
        log_success "Retrieved ArgoCD admin password"
    fi
}

################################################################################
# Datadog Secret Creation
################################################################################

create_datadog_secret() {
    log_step "Step 4: Datadog Secret Creation"

    CURRENT_STAGE="datadog_secret"

    # Create datadog namespace
    log_info "Creating datadog namespace..."
    if ! kubectl get namespace datadog >/dev/null 2>&1; then
        kubectl create namespace datadog
        log_success "Datadog namespace created"
    else
        log_info "Datadog namespace already exists"
    fi

    # Check if secret already exists
    if kubectl get secret datadog-secret -n datadog >/dev/null 2>&1; then
        log_warning "Secret 'datadog-secret' already exists in datadog namespace"

        if prompt_yes_no "Recreate the secret with current credentials?" "n"; then
            log_info "Deleting existing secret..."
            kubectl delete secret datadog-secret -n datadog
        else
            log_info "Keeping existing secret"

            # Verify secret has required keys
            log_info "Verifying secret has required keys..."
            if kubectl get secret datadog-secret -n datadog -o jsonpath='{.data.api-key}' >/dev/null 2>&1 && \
               kubectl get secret datadog-secret -n datadog -o jsonpath='{.data.app-key}' >/dev/null 2>&1; then
                log_success "Secret has required keys: api-key, app-key"
            else
                log_error "Secret is missing required keys"
                exit $EXIT_SECRET_CREATION_FAILED
            fi

            return 0
        fi
    fi

    # Create secret
    log_info "Creating datadog-secret with API and App keys..."
    if ! kubectl create secret generic datadog-secret \
        --from-literal=api-key="${DD_API_KEY}" \
        --from-literal=app-key="${DD_APP_KEY}" \
        -n datadog; then
        log_error "Failed to create datadog-secret"
        exit $EXIT_SECRET_CREATION_FAILED
    fi

    log_success "Datadog secret created"

    # Verify secret
    log_info "Verifying secret..."
    if kubectl get secret datadog-secret -n datadog -o jsonpath='{.data.api-key}' >/dev/null 2>&1 && \
       kubectl get secret datadog-secret -n datadog -o jsonpath='{.data.app-key}' >/dev/null 2>&1; then
        log_success "Secret verified with keys: api-key, app-key"
    else
        log_error "Secret verification failed"
        exit $EXIT_SECRET_CREATION_FAILED
    fi
}

################################################################################
# ArgoCD Application Deployment
################################################################################

deploy_root_application() {
    log_step "Step 5: ArgoCD Root Application Deployment"

    CURRENT_STAGE="root_application"

    detect_repo_url

    # Check if we need to patch the repository URL
    local manifest_repo_url
    manifest_repo_url=$(grep 'repoURL:' argocd/root-app.yaml | head -n1 | awk '{print $2}')

    if [[ "$manifest_repo_url" != "$REPO_URL" ]]; then
        log_warning "Manifest repository URL ($manifest_repo_url) differs from detected URL ($REPO_URL)"
        log_info "Manifests will be applied with detected URL"

        # Apply with kustomize to patch URL
        local temp_kustomization="/tmp/kustomization-$$.yaml"
        cat > "$temp_kustomization" << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../argocd/root-app.yaml

patches:
  - patch: |-
      - op: replace
        path: /spec/source/repoURL
        value: $REPO_URL
    target:
      kind: Application
      name: root-app
EOF

        log_info "Applying root application with patched repository URL..."
        if ! kubectl apply -k "$(dirname "$temp_kustomization")"; then
            rm -f "$temp_kustomization"
            log_error "Failed to apply root application"
            exit $EXIT_APP_DEPLOYMENT_FAILED
        fi

        rm -f "$temp_kustomization"
    else
        log_info "Repository URL matches manifest, applying directly..."
        if ! kubectl apply -f argocd/root-app.yaml; then
            log_error "Failed to apply root application"
            exit $EXIT_APP_DEPLOYMENT_FAILED
        fi
    fi

    log_success "Root application deployed"

    # Wait for root application to be created
    log_info "Waiting for root application to be created in ArgoCD..."
    if ! wait_for_condition \
        "Root application exists" \
        "kubectl get application root-app -n argocd" \
        60; then
        log_error "Root application was not created"
        exit $EXIT_APP_DEPLOYMENT_FAILED
    fi

    log_success "Root application created"

    # Wait for child applications to be created
    log_info "Waiting for child applications to be created..."
    sleep 10

    local expected_apps=("datadog-operator" "datadog-agent" "nginx-dka-demo")
    for app in "${expected_apps[@]}"; do
        if ! wait_for_condition \
            "Application $app exists" \
            "kubectl get application $app -n argocd" \
            60; then
            log_error "Application $app was not created by root app"
            exit $EXIT_APP_DEPLOYMENT_FAILED
        fi
        log_success "Application $app created"
    done

    log_success "All child applications created"
}

################################################################################
# Wave-Based Deployment Monitoring
################################################################################

wait_for_app_sync() {
    local app_name="$1"
    local timeout="$2"

    log_info "Waiting for $app_name to sync..."

    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        local sync_status
        sync_status=$(kubectl get application "$app_name" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")

        if [[ "$sync_status" == "Synced" ]]; then
            log_success "$app_name synced (${elapsed}s elapsed)"
            return 0
        fi

        if [[ "$sync_status" == "OutOfSync" ]] || [[ "$sync_status" == "Unknown" ]]; then
            # Check if there are any sync errors
            local conditions
            conditions=$(kubectl get application "$app_name" -n argocd -o jsonpath='{.status.conditions}' 2>/dev/null || echo "")
            if [[ "$conditions" == *"ComparisonError"* ]] || [[ "$conditions" == *"SyncError"* ]]; then
                log_error "$app_name has sync errors"
                kubectl get application "$app_name" -n argocd -o jsonpath='{.status.conditions}' | jq '.' 2>/dev/null || true
                return 1
            fi
        fi

        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))

        if [[ $((elapsed % 60)) -eq 0 ]]; then
            log_info "Still waiting for $app_name to sync (${elapsed}s elapsed, status: $sync_status)"
        fi
    done

    log_error "Timeout waiting for $app_name to sync"
    return 1
}

wait_for_app_health() {
    local app_name="$1"
    local timeout="$2"

    log_info "Waiting for $app_name to become healthy..."

    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        local health_status
        health_status=$(kubectl get application "$app_name" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")

        if [[ "$health_status" == "Healthy" ]]; then
            log_success "$app_name is healthy (${elapsed}s elapsed)"
            return 0
        fi

        if [[ "$health_status" == "Degraded" ]]; then
            log_error "$app_name is degraded"
            kubectl get application "$app_name" -n argocd -o jsonpath='{.status.conditions}' | jq '.' 2>/dev/null || true
            return 1
        fi

        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))

        if [[ $((elapsed % 60)) -eq 0 ]]; then
            log_info "Still waiting for $app_name to become healthy (${elapsed}s elapsed, status: $health_status)"
        fi
    done

    log_error "Timeout waiting for $app_name to become healthy"
    return 1
}

monitor_wave_deployment() {
    log_step "Step 6: Wave-Based Deployment Monitoring"

    # Wave 0: Datadog Operator
    log_info "=== Wave 0: Datadog Operator ==="
    CURRENT_STAGE="wave0_operator"

    if ! wait_for_app_sync "datadog-operator" "$TIMEOUT_APP_SYNC"; then
        log_error "Datadog Operator failed to sync"
        exit $EXIT_APP_SYNC_FAILED
    fi

    if ! wait_for_app_health "datadog-operator" "$TIMEOUT_APP_SYNC"; then
        log_error "Datadog Operator failed health check"
        exit $EXIT_APP_HEALTH_FAILED
    fi

    # Verify operator deployment
    log_info "Verifying Datadog Operator deployment..."
    if ! kubectl get deployment datadog-operator -n datadog >/dev/null 2>&1; then
        log_error "Datadog Operator deployment not found"
        exit $EXIT_VERIFICATION_FAILED
    fi

    if ! kubectl wait deployment/datadog-operator -n datadog --for=condition=Available --timeout=120s; then
        log_error "Datadog Operator deployment not ready"
        exit $EXIT_VERIFICATION_FAILED
    fi

    log_success "Datadog Operator deployment is ready"

    # Verify CRDs
    log_info "Verifying Datadog CRDs..."
    local expected_crds=("datadogagents.datadoghq.com" "datadogpodautoscalers.datadoghq.com")
    for crd in "${expected_crds[@]}"; do
        if ! kubectl get crd "$crd" >/dev/null 2>&1; then
            log_error "CRD not found: $crd"
            exit $EXIT_VERIFICATION_FAILED
        fi
        log_success "CRD found: $crd"
    done

    log_success "Wave 0 (Datadog Operator) completed"

    # Wave 1: DatadogAgent
    log_info ""
    log_info "=== Wave 1: DatadogAgent ==="
    CURRENT_STAGE="wave1_agent"

    if ! wait_for_app_sync "datadog-agent" "$TIMEOUT_APP_SYNC"; then
        log_error "DatadogAgent failed to sync"
        exit $EXIT_APP_SYNC_FAILED
    fi

    if ! wait_for_app_health "datadog-agent" "$TIMEOUT_APP_SYNC"; then
        log_error "DatadogAgent failed health check"
        exit $EXIT_APP_HEALTH_FAILED
    fi

    # Verify DatadogAgent CR
    log_info "Verifying DatadogAgent custom resource..."
    if ! kubectl get datadogagent -n datadog >/dev/null 2>&1; then
        log_error "DatadogAgent CR not found"
        exit $EXIT_VERIFICATION_FAILED
    fi

    local agent_name
    agent_name=$(kubectl get datadogagent -n datadog -o jsonpath='{.items[0].metadata.name}')
    log_success "DatadogAgent CR found: $agent_name"

    # Verify agent DaemonSet
    log_info "Verifying Datadog Agent DaemonSet..."
    if ! kubectl get daemonset -n datadog -l app=datadog >/dev/null 2>&1; then
        log_error "Datadog Agent DaemonSet not found"
        exit $EXIT_VERIFICATION_FAILED
    fi

    # Wait for agent pods to be running
    log_info "Waiting for Datadog Agent pods to be ready..."
    sleep 20  # Give some time for DaemonSet to create pods

    local agent_pods_ready=false
    for i in {1..12}; do
        local desired
        local ready
        desired=$(kubectl get daemonset -n datadog -l app=datadog -o jsonpath='{.items[0].status.desiredNumberScheduled}' 2>/dev/null || echo "0")
        ready=$(kubectl get daemonset -n datadog -l app=datadog -o jsonpath='{.items[0].status.numberReady}' 2>/dev/null || echo "0")

        if [[ "$desired" -gt 0 ]] && [[ "$ready" -eq "$desired" ]]; then
            agent_pods_ready=true
            break
        fi

        log_info "Waiting for agent pods: $ready/$desired ready (attempt $i/12)"
        sleep 10
    done

    if [[ "$agent_pods_ready" == "false" ]]; then
        log_warning "Not all agent pods are ready yet, but continuing..."
    else
        log_success "Datadog Agent DaemonSet is ready"
    fi

    # Verify cluster agent deployment
    log_info "Verifying Datadog Cluster Agent deployment..."
    if kubectl get deployment -n datadog -l app=datadog-cluster-agent >/dev/null 2>&1; then
        if kubectl wait deployment -n datadog -l app=datadog-cluster-agent --for=condition=Available --timeout=120s 2>/dev/null; then
            log_success "Datadog Cluster Agent is ready"
        else
            log_warning "Cluster Agent deployment not ready yet, but continuing..."
        fi
    else
        log_info "Cluster Agent deployment not found (may not be configured)"
    fi

    log_success "Wave 1 (DatadogAgent) completed"

    # Wave 2: NGINX Demo
    log_info ""
    log_info "=== Wave 2: NGINX Demo Application ==="
    CURRENT_STAGE="wave2_nginx"

    if ! wait_for_app_sync "nginx-dka-demo" "$TIMEOUT_APP_SYNC"; then
        log_error "NGINX Demo application failed to sync"
        exit $EXIT_APP_SYNC_FAILED
    fi

    if ! wait_for_app_health "nginx-dka-demo" "$TIMEOUT_APP_SYNC"; then
        log_error "NGINX Demo application failed health check"
        exit $EXIT_APP_HEALTH_FAILED
    fi

    # Verify NGINX deployment
    log_info "Verifying NGINX deployment..."
    if ! kubectl get deployment -n nginx-dka-demo >/dev/null 2>&1; then
        log_error "NGINX deployment not found"
        exit $EXIT_VERIFICATION_FAILED
    fi

    local nginx_deployment
    nginx_deployment=$(kubectl get deployment -n nginx-dka-demo -o jsonpath='{.items[0].metadata.name}')
    log_success "NGINX deployment found: $nginx_deployment"

    if ! kubectl wait deployment/"$nginx_deployment" -n nginx-dka-demo --for=condition=Available --timeout=180s; then
        log_error "NGINX deployment not ready"
        exit $EXIT_VERIFICATION_FAILED
    fi

    local replicas
    replicas=$(kubectl get deployment/"$nginx_deployment" -n nginx-dka-demo -o jsonpath='{.status.readyReplicas}')
    log_success "NGINX deployment is ready with $replicas replicas"

    # Verify DatadogPodAutoscaler
    log_info "Verifying DatadogPodAutoscaler..."
    if ! kubectl get datadogpodautoscaler -n nginx-dka-demo >/dev/null 2>&1; then
        log_error "DatadogPodAutoscaler not found"
        exit $EXIT_VERIFICATION_FAILED
    fi

    local dpa_name
    dpa_name=$(kubectl get datadogpodautoscaler -n nginx-dka-demo -o jsonpath='{.items[0].metadata.name}')
    log_success "DatadogPodAutoscaler found: $dpa_name"

    # Check DPA status
    log_info "Checking DatadogPodAutoscaler status..."
    sleep 10  # Give it a moment to initialize

    local dpa_conditions
    dpa_conditions=$(kubectl get datadogpodautoscaler "$dpa_name" -n nginx-dka-demo -o jsonpath='{.status.conditions}' 2>/dev/null || echo "[]")

    if [[ "$dpa_conditions" != "[]" ]] && [[ "$dpa_conditions" != "" ]]; then
        log_info "DPA Conditions:"
        echo "$dpa_conditions" | jq '.' 2>/dev/null || echo "$dpa_conditions"

        local active_status
        active_status=$(echo "$dpa_conditions" | jq -r '.[] | select(.type=="Active") | .status' 2>/dev/null || echo "Unknown")

        if [[ "$active_status" == "True" ]]; then
            log_success "DatadogPodAutoscaler is Active"
        else
            log_warning "DatadogPodAutoscaler is not yet Active (status: $active_status)"
        fi
    else
        log_warning "DatadogPodAutoscaler status not yet available"
    fi

    log_success "Wave 2 (NGINX Demo) completed"

    log_success "All deployment waves completed successfully"
}

################################################################################
# Verification
################################################################################

verify_deployment() {
    if [[ "$SKIP_VERIFY" == "true" ]]; then
        log_info "Skipping post-deployment verification (--skip-verify)"
        return 0
    fi

    log_step "Step 7: Deployment Verification"

    CURRENT_STAGE="verification"

    # Cluster health
    log_info "Verifying cluster health..."
    kubectl cluster-info
    log_success "Cluster is healthy"

    # ArgoCD applications
    log_info "Verifying ArgoCD applications..."
    echo ""
    kubectl get applications -n argocd
    echo ""

    local all_synced=true
    local all_healthy=true

    local apps=("root-app" "datadog-operator" "datadog-agent" "nginx-dka-demo")
    for app in "${apps[@]}"; do
        local sync_status
        local health_status
        sync_status=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.sync.status}')
        health_status=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.health.status}')

        if [[ "$sync_status" != "Synced" ]]; then
            log_warning "Application $app is not Synced (status: $sync_status)"
            all_synced=false
        fi

        if [[ "$health_status" != "Healthy" ]]; then
            log_warning "Application $app is not Healthy (status: $health_status)"
            all_healthy=false
        fi
    done

    if [[ "$all_synced" == "true" ]] && [[ "$all_healthy" == "true" ]]; then
        log_success "All ArgoCD applications are Synced and Healthy"
    else
        log_warning "Some applications are not in expected state"
    fi

    # Datadog components
    log_info "Verifying Datadog components..."
    echo ""
    kubectl get pods -n datadog
    echo ""

    # NGINX demo
    log_info "Verifying NGINX demo application..."
    echo ""
    kubectl get pods -n nginx-dka-demo
    echo ""

    # DatadogPodAutoscaler
    log_info "DatadogPodAutoscaler status:"
    echo ""
    kubectl get datadogpodautoscaler -n nginx-dka-demo
    echo ""

    local dpa_name
    dpa_name=$(kubectl get datadogpodautoscaler -n nginx-dka-demo -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -n "$dpa_name" ]]; then
        log_info "Detailed DPA status for $dpa_name:"
        kubectl describe datadogpodautoscaler "$dpa_name" -n nginx-dka-demo | grep -A 20 "Status:" || true
    fi

    log_success "Deployment verification completed"
}

################################################################################
# Status Output
################################################################################

show_deployment_summary() {
    log_step "Deployment Summary"

    cat << EOF

${COLOR_GREEN}${COLOR_BOLD}Deployment Completed Successfully!${COLOR_RESET}

${COLOR_CYAN}${COLOR_BOLD}Cluster Information:${COLOR_RESET}
  Profile: $MINIKUBE_PROFILE
  Status: Running
  CPUs: $MINIKUBE_CPUS
  Memory: ${MINIKUBE_MEMORY}MB
  Driver: $MINIKUBE_DRIVER

${COLOR_CYAN}${COLOR_BOLD}ArgoCD Access:${COLOR_RESET}
  UI URL: https://localhost:8080
  Username: admin
  Password: $ARGOCD_PASSWORD

  To access the ArgoCD UI, run in another terminal:
    ${COLOR_YELLOW}kubectl port-forward svc/argocd-server -n argocd 8080:443${COLOR_RESET}

  Then open: ${COLOR_YELLOW}https://localhost:8080${COLOR_RESET}

${COLOR_CYAN}${COLOR_BOLD}Deployed Components:${COLOR_RESET}
  ✓ Datadog Operator (Wave 0)
  ✓ Datadog Agent (Wave 1)
  ✓ NGINX Demo Application (Wave 2)
  ✓ DatadogPodAutoscaler

${COLOR_CYAN}${COLOR_BOLD}Next Steps:${COLOR_RESET}
  1. Access ArgoCD UI to monitor applications
  2. Check DatadogPodAutoscaler status:
     ${COLOR_YELLOW}kubectl get datadogpodautoscaler -n nginx-dka-demo${COLOR_RESET}

  3. View autoscaler details:
     ${COLOR_YELLOW}kubectl describe datadogpodautoscaler -n nginx-dka-demo${COLOR_RESET}

  4. Monitor NGINX deployment scaling:
     ${COLOR_YELLOW}kubectl get deployment -n nginx-dka-demo -w${COLOR_RESET}

  5. View Datadog Agent logs:
     ${COLOR_YELLOW}kubectl logs -n datadog -l app=datadog --tail=50${COLOR_RESET}

${COLOR_CYAN}${COLOR_BOLD}Useful Commands:${COLOR_RESET}
  # View all ArgoCD applications
  kubectl get applications -n argocd

  # Check pod status across all namespaces
  kubectl get pods -A

  # Access minikube dashboard
  minikube dashboard -p $MINIKUBE_PROFILE

  # Delete the cluster when done
  minikube delete -p $MINIKUBE_PROFILE

EOF

    log_success "Setup complete! Your DKA demo environment is ready."
}

################################################################################
# Cleanup and Error Handling
################################################################################

cleanup_on_error() {
    local exit_code=$1

    log_error "Deployment failed at stage: $CURRENT_STAGE (exit code: $exit_code)"

    if [[ "$CLEANUP_ON_ERROR" != "true" ]]; then
        log_info "Cleanup not requested. Resources remain for troubleshooting."
        log_info "To cleanup manually:"
        echo "  kubectl delete namespace datadog nginx-dka-demo argocd --ignore-not-found=true"
        echo "  minikube delete -p $MINIKUBE_PROFILE"
        return
    fi

    log_warning "Cleanup on error is enabled. Cleaning up resources..."

    # Delete ArgoCD applications
    if [[ "$CURRENT_STAGE" != "initialization" ]] && [[ "$CURRENT_STAGE" != "minikube_cluster" ]]; then
        log_info "Deleting ArgoCD applications..."
        kubectl delete applications --all -n argocd --ignore-not-found=true --timeout=60s 2>/dev/null || true
    fi

    # Delete namespaces
    if [[ "$CURRENT_STAGE" != "initialization" ]] && [[ "$CURRENT_STAGE" != "minikube_cluster" ]]; then
        log_info "Deleting namespaces..."
        kubectl delete namespace datadog nginx-dka-demo argocd --ignore-not-found=true --timeout=120s 2>/dev/null || true
    fi

    # Optionally delete cluster
    if [[ "$CURRENT_STAGE" == "minikube_cluster" ]] || prompt_yes_no "Delete minikube cluster?" "n"; then
        log_info "Deleting minikube cluster..."
        minikube delete -p "$MINIKUBE_PROFILE" 2>/dev/null || true
    fi

    log_info "Cleanup completed"
}

trap_exit() {
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        cleanup_on_error "$exit_code"
    fi
}

trap trap_exit EXIT

################################################################################
# Main Function
################################################################################

main() {
    # Parse arguments
    parse_args "$@"

    # Run deployment steps
    check_prerequisites
    create_or_start_minikube
    install_argocd
    create_datadog_secret
    deploy_root_application
    monitor_wave_deployment
    verify_deployment
    show_deployment_summary

    log_success "Deployment script completed successfully!"
}

################################################################################
# Script Entry Point
################################################################################

main "$@"
