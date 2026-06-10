#!/bin/bash
set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
NAMESPACE=""
OUTPUT_DIR="."
PIPELINERUN=""
SHOW_HELP=false
USE_KUBEARCHIVE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            SHOW_HELP=true
            shift
            ;;
        --namespace|-n)
            NAMESPACE="$2"
            shift 2
            ;;
        --output-dir|-o)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --*)
            echo -e "${RED}Error: Unknown flag $1${NC}"
            exit 1
            ;;
        *)
            if [[ -z "$PIPELINERUN" ]]; then
                PIPELINERUN="$1"
            else
                echo -e "${RED}Error: Multiple PipelineRun names provided${NC}"
                exit 1
            fi
            shift
            ;;
    esac
done

# Help text
if [[ "$SHOW_HELP" == "true" ]]; then
    cat <<'EOF'
Download Artifacts - Konflux PipelineRun Artifact Downloader

DESCRIPTION:
    Downloads artifacts and logs from Tekton PipelineRuns in Konflux.
    Retrieves Trusted Artifacts from OCI registries and task logs,
    organizing them by task in a structured directory.

REQUIRED TOOLS:
    - oc or kubectl: OpenShift/Kubernetes CLI
      Install: https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html
    - tkn: Tekton CLI
      Install: https://tekton.dev/docs/cli/
    - jq: JSON processor
      Install: https://jqlang.github.io/jq/download/

    For downloading artifacts, install one of:
    - oras (recommended): OCI Registry As Storage CLI
      Install: https://oras.land/
    - podman: Container management tool
      Install: https://podman.io/

OPTIONAL TOOLS (for archived PipelineRuns):
    - kubectl ka: KubeArchive CLI plugin
      Install: https://kubearchive.github.io/kubearchive/main/cli/installation.html
      Automatically configured from current cluster context

USAGE:
    download-artifacts [PIPELINERUN] [OPTIONS]

ARGUMENTS:
    PIPELINERUN          Name of the PipelineRun (optional, will prompt if not provided)

OPTIONS:
    -n, --namespace NS   Kubernetes namespace (default: current context namespace)
    -o, --output-dir DIR Output directory (default: current directory)
    -h, --help           Show this help message

EXAMPLES:
    # Interactive mode - prompts for PipelineRun
    /download-artifacts

    # Download specific PipelineRun
    /download-artifacts my-build-run-abc123

    # Specify namespace and output directory
    /download-artifacts my-build-run --namespace my-tenant --output-dir /tmp/builds

    # Short flags
    /download-artifacts my-build-run -n my-tenant -o ./artifacts

AUTHENTICATION:
    You must be logged into the cluster before running this skill:
        oc login <cluster-api-url>

OUTPUT STRUCTURE:
    <pipelinerun-name>/
        <task-name-1>/
            <step-1>.log
            <step-2>.log
            <artifact-files>
        <task-name-2>/
            ...

EOF
    exit 0
fi

# Function to print colored messages
info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

success() {
    echo -e "${GREEN}✓${NC} $1"
}

warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

error() {
    echo -e "${RED}✗${NC} $1"
}

# Format a PipelineRun list entry with status coloring
format_pr_line() {
    local idx=$1 name=$2 status=$3 timestamp=$4
    local status_color=""
    case "$status" in
        Succeeded) status_color="${GREEN}" ;;
        Failed) status_color="${RED}" ;;
        Running) status_color="${YELLOW}" ;;
        *) status_color="${NC}" ;;
    esac
    printf "%2d) %-50s ${status_color}%-12s${NC} %s\n" "$idx" "$name" "$status" "$timestamp"
}

# Fetch PipelineRun JSON (handles both live and archive)
fetch_pipelinerun() {
    local pr_name="$1"
    if [[ "$USE_KUBEARCHIVE" == "true" ]]; then
        setup_kubearchive_host
        kubectl ka get pipelinerun "$pr_name" -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[0] // {}'
    else
        $KUBECTL get pipelinerun "$pr_name" -n "$NAMESPACE" -o json 2>/dev/null || echo "{}"
    fi
}

# Fetch TaskRun JSON (handles both live and archive)
fetch_taskrun() {
    local taskrun_name="$1"
    if [[ "$USE_KUBEARCHIVE" == "true" ]]; then
        setup_kubearchive_host
        kubectl ka get taskrun "$taskrun_name" -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[0] // {}'
    else
        $KUBECTL get taskrun "$taskrun_name" -n "$NAMESPACE" -o json 2>/dev/null || echo "{}"
    fi
}

# Check required tools
check_tools() {
    local missing_tools=()
    local missing_artifact_tools=()

    # Check for oc or kubectl
    if ! command -v oc &> /dev/null && ! command -v kubectl &> /dev/null; then
        missing_tools+=("oc or kubectl")
    fi

    # Check for tkn
    if ! command -v tkn &> /dev/null; then
        missing_tools+=("tkn")
    fi

    # Check for jq
    if ! command -v jq &> /dev/null; then
        missing_tools+=("jq")
    fi

    # Check for artifact download tools
    if ! command -v oras &> /dev/null && ! command -v podman &> /dev/null; then
        missing_artifact_tools+=("oras or podman")
    fi

    if [[ ${#missing_tools[@]} -gt 0 ]] || [[ ${#missing_artifact_tools[@]} -gt 0 ]]; then
        error "Required tools not found:"
        for tool in "${missing_tools[@]}"; do
            echo "  - $tool"
        done
        echo ""
        if [[ ${#missing_artifact_tools[@]} -gt 0 ]]; then
            echo "For downloading artifacts, install one of:"
            echo "  - oras (recommended): https://oras.land/ (dnf install golang-oras)"
            echo "  - podman: https://podman.io/ (dnf install podman)"
        fi
        echo ""
        echo "Installation guides:"
        echo "  - oc: https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html"
        echo "  - tkn: https://tekton.dev/docs/cli/"
        echo "  - jq: https://jqlang.github.io/jq/download/ (dnf install jq)"
        exit 1
    fi

    # Determine which kubectl command to use
    if command -v oc &> /dev/null; then
        KUBECTL="oc"
    else
        KUBECTL="kubectl"
    fi
}

# Check if logged in
check_login() {
    if ! $KUBECTL whoami &> /dev/null; then
        error "Not logged into any cluster"
        echo "Please run: oc login <cluster-api-url>"
        exit 1
    fi

    local current_cluster
    current_cluster=$($KUBECTL config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "unknown")
    info "Using cluster: $current_cluster"
}

# Get namespace
get_namespace() {
    if [[ -z "$NAMESPACE" ]]; then
        NAMESPACE=$($KUBECTL config view --minify -o jsonpath='{..namespace}' 2>/dev/null || echo "")
        if [[ -z "$NAMESPACE" ]]; then
            NAMESPACE="default"
        fi
    fi
    info "Using namespace: $NAMESPACE"
}

# Setup kubearchive host (idempotent, caches result)
setup_kubearchive_host() {
    [[ -n "${_KUBEARCHIVE_SETUP_DONE:-}" ]] && return 0

    if [[ -z "${KUBECTL_PLUGIN_KA_HOST:-}" ]]; then
        # Auto-configure from current cluster
        local server
        server=$($KUBECTL config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "")
        if [[ -n "$server" ]]; then
            local cluster_domain
            cluster_domain=$(echo "$server" | sed -E 's|^.*api\.?(.*):[0-9]+$|\1|')
            export KUBECTL_PLUGIN_KA_HOST="https://kubearchive-api-server-product-kubearchive.apps.${cluster_domain}"
        fi
    fi

    _KUBEARCHIVE_SETUP_DONE=1
}

# List recent PipelineRuns
list_pipelineruns() {
    info "Fetching recent PipelineRuns..."
    local prs
    prs=$($KUBECTL get pipelinerun -n "$NAMESPACE" -o json 2>/dev/null || echo "{}")

    local live_count
    live_count=$(echo "$prs" | jq -r '.items | length')

    if [[ $live_count -eq 0 ]]; then
        warn "No live PipelineRuns found in namespace $NAMESPACE"

        # Check if kubearchive is available
        if command -v kubearchive &> /dev/null; then
            info "Trying kubearchive for archived PipelineRuns..."
            if ! try_kubearchive_list; then
                error "No PipelineRuns found (live or archived)"
                exit 1
            fi
            return
        else
            echo ""
            echo "Tip: Install kubearchive to access older archived PipelineRuns:"
            echo "  https://github.com/kubearchive/kubearchive"
            exit 1
        fi
    fi

    echo ""
    echo "Recent PipelineRuns:"
    echo "-------------------"

    local pr_data
    pr_data=$(echo "$prs" | jq -r '.items | sort_by(.metadata.creationTimestamp) | reverse | .[0:20] | .[] |
        "\(.metadata.name)|\(.status.conditions[0].reason // "Unknown")|\(.metadata.creationTimestamp)"')

    local idx=1
    declare -g -A PR_MAP
    while IFS='|' read -r name status timestamp; do
        PR_MAP[$idx]="$name"
        format_pr_line "$idx" "$name" "$status" "$timestamp"
        ((idx++))
    done <<< "$pr_data"

    echo ""
    read -p "Select PipelineRun number (or 'a' to search archive): " selection

    if [[ "$selection" == "a" ]] || [[ "$selection" == "archive" ]]; then
        if command -v kubearchive &> /dev/null; then
            if ! try_kubearchive_list; then
                error "Failed to retrieve archived PipelineRuns"
                exit 1
            fi
        else
            error "kubearchive not installed. Install from: https://github.com/kubearchive/kubearchive"
            exit 1
        fi
        return
    fi

    if [[ ! "$selection" =~ ^[0-9]+$ ]] || [[ -z "${PR_MAP[$selection]:-}" ]]; then
        error "Invalid selection"
        exit 1
    fi

    PIPELINERUN="${PR_MAP[$selection]}"
    USE_KUBEARCHIVE=false
    success "Selected: $PIPELINERUN"
}

# Try listing PipelineRuns from kubearchive
try_kubearchive_list() {
    info "Searching kubearchive for PipelineRuns..."

    # Set kubearchive host if not already set
    setup_kubearchive_host

    local archived_prs
    archived_prs=$(kubectl ka get pipelinerun -n "$NAMESPACE" --limit 50 -o json 2>/dev/null || echo "")

    if [[ -z "$archived_prs" ]]; then
        warn "No archived PipelineRuns found in kubearchive"
        return 1
    fi

    echo ""
    echo "Archived PipelineRuns (from kubearchive):"
    echo "-----------------------------------------"

    local pr_data
    pr_data=$(echo "$archived_prs" | jq -r '.items[]? |
        "\(.metadata.name)|\(.status.conditions[0]?.reason // "Unknown")|\(.metadata.creationTimestamp)"' 2>/dev/null || echo "")

    if [[ -z "$pr_data" ]]; then
        warn "Could not parse archived PipelineRuns"
        return 1
    fi

    local idx=1
    unset PR_MAP
    declare -g -A PR_MAP
    while IFS='|' read -r name status timestamp; do
        PR_MAP[$idx]="$name"
        format_pr_line "$idx" "$name" "$status" "$timestamp"
        ((idx++))
    done <<< "$pr_data"

    echo ""
    read -p "Select PipelineRun number: " selection

    if [[ ! "$selection" =~ ^[0-9]+$ ]] || [[ -z "${PR_MAP[$selection]:-}" ]]; then
        error "Invalid selection"
        return 1
    fi

    PIPELINERUN="${PR_MAP[$selection]}"
    USE_KUBEARCHIVE=true
    success "Selected (from archive): $PIPELINERUN"
    return 0
}

# Get PipelineRun details
get_pipelinerun_details() {
    info "Fetching PipelineRun details..."

    PR_JSON=$(fetch_pipelinerun "$PIPELINERUN")

    if [[ $(echo "$PR_JSON" | jq -r '.metadata.name // empty') != "$PIPELINERUN" ]]; then
        if [[ "$USE_KUBEARCHIVE" == "true" ]]; then
            error "PipelineRun '$PIPELINERUN' not found in kubearchive for namespace $NAMESPACE"
            exit 1
        else
            # Not found in live cluster, try kubearchive automatically
            if command -v kubectl &> /dev/null && kubectl ka version &> /dev/null 2>&1; then
                info "PipelineRun not found in live cluster, trying kubearchive..."
                USE_KUBEARCHIVE=true
                PR_JSON=$(fetch_pipelinerun "$PIPELINERUN")

                if [[ $(echo "$PR_JSON" | jq -r '.metadata.name // empty') != "$PIPELINERUN" ]]; then
                    error "PipelineRun '$PIPELINERUN' not found in live cluster or kubearchive"
                    exit 1
                fi
                success "Found PipelineRun in kubearchive"
            else
                error "PipelineRun '$PIPELINERUN' not found in namespace $NAMESPACE"
                echo ""
                echo "Tip: Install kubectl ka to access archived PipelineRuns:"
                echo "  https://kubearchive.github.io/kubearchive/main/cli/installation.html"
                exit 1
            fi
        fi
    fi

    local pr_status
    pr_status=$(echo "$PR_JSON" | jq -r '.status.conditions[0].reason // "Unknown"')

    local running_count completed_count total_count
    completed_count=$(echo "$PR_JSON" | jq -r '[.status.childReferences[]? | select(.kind == "TaskRun") | select(.pipelineTaskName != null)] | length')
    total_count=$(echo "$PR_JSON" | jq -r '[.spec.pipelineSpec.tasks[]?, .spec.pipelineSpec.finally[]?] | length')

    if [[ "$USE_KUBEARCHIVE" == "true" ]]; then
        info "Pipeline status (archived): $pr_status ($completed_count/$total_count tasks completed)"
    else
        info "Pipeline status: $pr_status ($completed_count/$total_count tasks completed)"
    fi
}

# Get pull credentials for artifacts from ImageRepository
get_pull_credentials() {
    info "Fetching artifact pull credentials..."

    # Get component name from PipelineRun labels
    local component
    component=$(echo "$PR_JSON" | jq -r '.metadata.labels["appstudio.openshift.io/component"] // empty')

    if [[ -z "$component" ]]; then
        warn "No component label found in PipelineRun, artifacts may not be accessible"
        return 1
    fi

    # Find ImageRepository for this component
    local imagerepository
    imagerepository=$($KUBECTL get imagerepository -n "$NAMESPACE" \
        -l "appstudio.redhat.com/component=$component" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$imagerepository" ]]; then
        warn "No ImageRepository found for component '$component'"
        return 1
    fi

    # Get pull secret name from ImageRepository
    local pull_secret
    pull_secret=$($KUBECTL get imagerepository "$imagerepository" -n "$NAMESPACE" \
        -o jsonpath='{.status.credentials.pull-secret}' 2>/dev/null || echo "")

    if [[ -z "$pull_secret" ]]; then
        warn "No pull secret found in ImageRepository '$imagerepository'"
        return 1
    fi

    # Get the dockerconfigjson from the secret
    local dockerconfig
    dockerconfig=$($KUBECTL get secret "$pull_secret" -n "$NAMESPACE" \
        -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null || echo "")

    if [[ -z "$dockerconfig" ]]; then
        warn "Could not read pull secret '$pull_secret'"
        return 1
    fi

    # Store credentials globally for artifact download
    declare -g ARTIFACT_PULL_SECRET
    ARTIFACT_PULL_SECRET=$(echo "$dockerconfig" | base64 -d)

    success "Artifact credentials loaded from $pull_secret"
    return 0
}

# List and select tasks
select_tasks() {
    info "Fetching task list..."

    # Get TaskRun names from PipelineRun childReferences
    local taskrun_refs
    taskrun_refs=$(echo "$PR_JSON" | jq -r '
        [.status.childReferences[]? |
         select(.kind == "TaskRun") |
         select(.pipelineTaskName != null) |
         {
             name: .name,
             taskName: .pipelineTaskName
         }
        ] | .[]
    ')

    if [[ -z "$taskrun_refs" ]]; then
        error "No tasks found in PipelineRun"
        exit 1
    fi

    # Fetch actual TaskRun resources to get status
    # Group by task name and select the best TaskRun for each task
    declare -g -A TASK_MAP
    declare -g -A TASKRUN_MAP
    declare -A TASK_STATUS_MAP
    declare -A TASK_TASKRUNS  # Tracks all TaskRuns per task name

    while read -r ref; do
        local taskrun_name task_name
        taskrun_name=$(echo "$ref" | jq -r '.name')
        task_name=$(echo "$ref" | jq -r '.taskName')

        # Get TaskRun status (from live cluster or kubearchive)
        local status
        local taskrun_json
        taskrun_json=$(fetch_taskrun "$taskrun_name")
        status=$(echo "$taskrun_json" | jq -r '.status.conditions[0]?.reason // "Unknown"')

        # Track this TaskRun for this task
        if [[ -z "${TASK_TASKRUNS[$task_name]:-}" ]]; then
            TASK_TASKRUNS[$task_name]="$taskrun_name:$status"
        else
            TASK_TASKRUNS[$task_name]="${TASK_TASKRUNS[$task_name]} $taskrun_name:$status"
        fi
    done < <(echo "$taskrun_refs" | jq -c '.')

    # Now select the best TaskRun for each task (prefer Succeeded, then latest)
    for task_name in "${!TASK_TASKRUNS[@]}"; do
        local best_taskrun=""
        local best_status="Unknown"

        # Parse all TaskRuns for this task
        for entry in ${TASK_TASKRUNS[$task_name]}; do
            local tr_name="${entry%:*}"
            local tr_status="${entry#*:}"

            # Prefer Succeeded status
            if [[ "$tr_status" == "Succeeded" ]]; then
                best_taskrun="$tr_name"
                best_status="$tr_status"
                break
            elif [[ -z "$best_taskrun" ]]; then
                # Take first one if no Succeeded found yet
                best_taskrun="$tr_name"
                best_status="$tr_status"
            fi
        done

        TASKRUN_MAP[$task_name]="$best_taskrun"
        TASK_STATUS_MAP[$task_name]="$best_status"
    done

    # Display tasks
    echo ""
    echo "Available tasks:"
    echo "----------------"

    local idx=1
    # Sort task names for consistent display
    for task_name in $(printf '%s\n' "${!TASKRUN_MAP[@]}" | sort); do
        TASK_MAP[$idx]="$task_name"
        local status="${TASK_STATUS_MAP[$task_name]}"
        # Format with shorter name field for tasks (40 chars vs 50 for PRs)
        local status_color=""
        case "$status" in
            Succeeded) status_color="${GREEN}" ;;
            Failed) status_color="${RED}" ;;
            Running) status_color="${YELLOW}" ;;
            *) status_color="${NC}" ;;
        esac
        printf "%2d) %-40s ${status_color}%-12s${NC}\n" "$idx" "$task_name" "$status"
        ((idx++))
    done

    echo ""
    echo "Enter task numbers (comma-separated, e.g., '1,3,5' or 'all'):"
    read -p "> " selection

    declare -g -a SELECTED_TASKS

    if [[ "$selection" == "all" ]]; then
        for i in "${!TASK_MAP[@]}"; do
            SELECTED_TASKS+=("${TASK_MAP[$i]}")
        done
    else
        IFS=',' read -ra NUMS <<< "$selection"
        for num in "${NUMS[@]}"; do
            num=$(echo "$num" | xargs) # trim whitespace
            if [[ "$num" =~ ^[0-9]+$ ]] && [[ -n "${TASK_MAP[$num]:-}" ]]; then
                SELECTED_TASKS+=("${TASK_MAP[$num]}")
            else
                warn "Ignoring invalid selection: $num"
            fi
        done
    fi

    if [[ ${#SELECTED_TASKS[@]} -eq 0 ]]; then
        error "No valid tasks selected"
        exit 1
    fi

    success "Selected ${#SELECTED_TASKS[@]} task(s)"
}

# Download artifacts using oras or podman
download_artifact() {
    local artifact_uri="$1"
    local output_path="$2"

    # Create output directory with permissive permissions for container extraction
    mkdir -p "$output_path"
    chmod 777 "$output_path"

    # Strip 'oci:' prefix for oras, keep it for build-trusted-artifacts
    local oras_uri="${artifact_uri#oci:}"

    # Prepare credentials if available
    local temp_auth_file=""
    if [[ -n "${ARTIFACT_PULL_SECRET:-}" ]]; then
        temp_auth_file=$(mktemp)
        echo "$ARTIFACT_PULL_SECRET" > "$temp_auth_file"
    fi

    # Prefer podman with build-trusted-artifacts over oras
    # Reason: TaskRun results may contain blob digests instead of manifest digests,
    # and build-trusted-artifacts uses "oras blob fetch" which handles both cases
    if command -v podman &> /dev/null; then
        # Use podman with build-trusted-artifacts image (expects oci: prefix)
        # Extract to /tmp first to avoid virtiofs permission issues, then copy to final destination
        local temp_extract_dir=$(mktemp -d)
        local container_output="/tmp/output"
        # Ensure artifact_uri has oci: prefix
        [[ "$artifact_uri" != oci:* ]] && artifact_uri="oci:$artifact_uri"

        # Use pull credentials if available, otherwise try system config
        local auth_opts=""
        if [[ -n "$temp_auth_file" ]]; then
            # Use the credentials from ImageRepository
            auth_opts="-v $temp_auth_file:/run/containers/0/auth.json:ro"
        elif [[ -f "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/auth.json" ]]; then
            auth_opts="-v ${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/auth.json:/run/containers/0/auth.json:ro"
        elif [[ -f "$HOME/.docker/config.json" ]]; then
            auth_opts="-v $HOME/.docker/config.json:/run/containers/0/auth.json:ro"
        fi

        local error_log=$(mktemp)
        if podman run --rm \
            $auth_opts \
            -v "$temp_extract_dir:$container_output:Z" \
            quay.io/konflux-ci/build-trusted-artifacts@sha256:90a188e90bf8f33cf93016bcfdfd0a3a9e7df6ff13691f001a0ed4f014060e2e \
            use "$artifact_uri=$container_output" 2>"$error_log"; then
            # Successfully extracted to temp directory, now copy to final destination
            if ls "$temp_extract_dir"/* &>/dev/null 2>&1; then
                cp -r "$temp_extract_dir"/* "$output_path/" 2>/dev/null || true
                rm -rf "$temp_extract_dir"
                rm -f "$error_log" "$temp_auth_file"
                return 0
            else
                # No files extracted
                rm -rf "$temp_extract_dir"
                rm -f "$error_log" "$temp_auth_file"
                return 1
            fi
        else
            # Check if files were extracted despite non-zero exit (permission warnings)
            if ls "$temp_extract_dir"/* &>/dev/null 2>&1; then
                # Files were extracted despite warnings, copy them
                cp -r "$temp_extract_dir"/* "$output_path/" 2>/dev/null || true
                rm -rf "$temp_extract_dir"
                rm -f "$error_log" "$temp_auth_file"
                return 0
            else
                local error_msg=$(cat "$error_log" | grep -E "(error|Error|failed|Failed|not found)" | head -2 | tr '\n' ' ')
                [[ -z "$error_msg" ]] && error_msg="Authentication or network issue - artifacts may require cluster credentials"
                warn "Artifact download failed: $error_msg"
                rm -rf "$temp_extract_dir"
                rm -f "$error_log" "$temp_auth_file"
                return 1
            fi
        fi
    elif command -v oras &> /dev/null; then
        # Fallback to oras (needs URI without oci: prefix)
        # Note: oras pull only works with manifest digests, not blob digests
        local error_log=$(mktemp)
        local oras_cmd="oras pull \"$oras_uri\" -o \"$output_path\""

        # Add credentials if available
        if [[ -n "$temp_auth_file" ]]; then
            oras_cmd="oras pull \"$oras_uri\" -o \"$output_path\" --registry-config \"$temp_auth_file\""
        fi

        if eval $oras_cmd 2>"$error_log"; then
            rm -f "$error_log" "$temp_auth_file"
            return 0
        else
            warn "oras pull failed (may need podman for blob digests): $(cat "$error_log" | head -3 | tr '\n' ' ')"
            rm -f "$error_log" "$temp_auth_file"
            return 1
        fi
    else
        error "No artifact download tool available (need podman or oras)"
        return 1
    fi
}

# Download task logs (per-step)
download_task_logs() {
    local task_name="$1"
    local taskrun_name="$2"
    local output_dir="$3"

    mkdir -p "$output_dir"

    # Get TaskRun details to find step names
    local taskrun_json
    taskrun_json=$(fetch_taskrun "$taskrun_name")

    if [[ $(echo "$taskrun_json" | jq -r '.metadata.name // empty') != "$taskrun_name" ]]; then
        warn "TaskRun '$taskrun_name' not found"
        return 1
    fi

    # Get list of steps
    local steps
    steps=$(echo "$taskrun_json" | jq -r '.status.steps[]?.name // empty')

    if [[ -z "$steps" ]]; then
        warn "No steps found in TaskRun"
        return 1
    fi

    local success_count=0
    local fail_count=0

    if [[ "$USE_KUBEARCHIVE" == "true" ]]; then
        # For archived TaskRuns, get container logs from kubearchive
        # Each step runs in a container, get pod logs for each container
        setup_kubearchive_host

        # Get pod name from TaskRun
        local pod_name
        pod_name=$(echo "$taskrun_json" | jq -r '.status.podName // empty')

        if [[ -z "$pod_name" ]]; then
            warn "No pod name found in archived TaskRun"
            return 1
        fi

        while read -r step_name; do
            [[ -z "$step_name" ]] && continue

            local log_file="$output_dir/${step_name}.log"
            # Use kubectl ka logs to get container logs from archived pod
            if kubectl ka logs "pod/$pod_name" -n "$NAMESPACE" -c "step-$step_name" > "$log_file" 2>/dev/null; then
                ((success_count++))
            else
                # Try without "step-" prefix
                if kubectl ka logs "pod/$pod_name" -n "$NAMESPACE" -c "$step_name" > "$log_file" 2>/dev/null; then
                    ((success_count++))
                else
                    ((fail_count++))
                    rm -f "$log_file"
                fi
            fi
        done <<< "$steps"
    else
        # For live TaskRuns, use tkn CLI
        while read -r step_name; do
            [[ -z "$step_name" ]] && continue

            local log_file="$output_dir/${step_name}.log"
            if tkn taskrun logs "$taskrun_name" -n "$NAMESPACE" -s "$step_name" > "$log_file" 2>/dev/null; then
                ((success_count++))
            else
                ((fail_count++))
                rm -f "$log_file"
            fi
        done <<< "$steps"
    fi

    if [[ $success_count -gt 0 ]]; then
        return 0
    else
        return 1
    fi
}

# Download task artifacts and logs
download_task() {
    local task_name="$1"
    local task_num="$2"
    local total_tasks="$3"

    info "Downloading task $task_num/$total_tasks: $task_name"

    local taskrun_name="${TASKRUN_MAP[$task_name]}"
    local task_dir="$TARGET_DIR/$task_name"

    mkdir -p "$task_dir"

    local artifacts_success=false
    local logs_success=false

    # Try to download artifacts
    local taskrun_json
    taskrun_json=$(fetch_taskrun "$taskrun_name")

    # Look for artifact results - get both name and value
    # Match result names ending with "artifact" or "-artifact" (case-insensitive)
    local artifact_data
    artifact_data=$(echo "$taskrun_json" | jq -r '.status.results[]? | select(.name | test("(^|[-_])artifact$"; "i")) | "\(.name)|\(.value)"' 2>/dev/null || echo "")

    if [[ -n "$artifact_data" ]]; then
        while IFS='|' read -r artifact_name uri; do
            [[ -z "$uri" ]] && continue
            # Create subdirectory for this artifact
            local artifact_dir="$task_dir/$artifact_name"
            mkdir -p "$artifact_dir"
            if download_artifact "$uri" "$artifact_dir"; then
                artifacts_success=true
            fi
        done <<< "$artifact_data"
    fi

    # Always download logs
    if download_task_logs "$task_name" "$taskrun_name" "$task_dir"; then
        logs_success=true
    fi

    # Report results
    if [[ "$artifacts_success" == "true" ]] && [[ "$logs_success" == "true" ]]; then
        DOWNLOAD_RESULTS["$task_name"]="success-both"
        success "$task_name (artifacts + logs)"
    elif [[ "$artifacts_success" == "true" ]]; then
        DOWNLOAD_RESULTS["$task_name"]="success-artifacts"
        success "$task_name (artifacts only)"
    elif [[ "$logs_success" == "true" ]]; then
        DOWNLOAD_RESULTS["$task_name"]="success-logs"
        success "$task_name (logs only)"
    else
        DOWNLOAD_RESULTS["$task_name"]="failed"
        error "$task_name (failed)"
    fi
}

# Main download process
download_all_tasks() {
    local task_num=1
    local total_tasks=${#SELECTED_TASKS[@]}

    declare -g -A DOWNLOAD_RESULTS

    for task_name in "${SELECTED_TASKS[@]}"; do
        download_task "$task_name" "$task_num" "$total_tasks"
        ((task_num++))
    done
}

# Print summary
print_summary() {
    echo ""
    echo "================================================"
    echo "Download Summary"
    echo "================================================"

    local success_both=0
    local success_artifacts=0
    local success_logs=0
    local failed=0

    for task_name in "${!DOWNLOAD_RESULTS[@]}"; do
        case "${DOWNLOAD_RESULTS[$task_name]}" in
            success-both)
                ((success_both++))
                success "$task_name (artifacts + logs)"
                ;;
            success-artifacts)
                ((success_artifacts++))
                warn "$task_name (artifacts only, no logs)"
                ;;
            success-logs)
                ((success_logs++))
                warn "$task_name (logs only, no artifacts)"
                ;;
            failed)
                ((failed++))
                error "$task_name (failed)"
                ;;
        esac
    done

    echo ""
    local total=$((success_both + success_artifacts + success_logs + failed))
    local successful=$((success_both + success_artifacts + success_logs))

    if [[ $failed -eq 0 ]]; then
        success "Downloaded $successful/$total tasks successfully"
    else
        warn "Downloaded $successful/$total tasks ($failed failed)"
    fi

    echo ""
    info "Output directory: $TARGET_DIR"
}

# Main execution
main() {
    check_tools
    check_login
    get_namespace

    # Get PipelineRun name if not provided
    if [[ -z "$PIPELINERUN" ]]; then
        list_pipelineruns
    fi

    get_pipelinerun_details
    get_pull_credentials || warn "Continuing without artifact credentials"
    select_tasks

    # Set up target directory
    TARGET_DIR="$OUTPUT_DIR/$PIPELINERUN"

    # Check if directory exists
    if [[ -d "$TARGET_DIR" ]]; then
        warn "Directory already exists: $TARGET_DIR"
        read -p "Overwrite? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            info "Cancelled"
            exit 0
        fi
        rm -rf "$TARGET_DIR"
    fi

    mkdir -p "$TARGET_DIR"

    download_all_tasks
    print_summary
}

main
