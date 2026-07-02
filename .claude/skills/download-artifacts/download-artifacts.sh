#!/bin/bash
set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Track temp files for cleanup on signal
_TEMP_FILES=()
_global_cleanup() {
    for f in "${_TEMP_FILES[@]}"; do
        rm -f "$f" 2>/dev/null
    done
}
trap _global_cleanup EXIT

# Default values
NAMESPACE=""
OUTPUT_DIR="."
PIPELINERUN=""
TASKS=""
SHOW_HELP=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            SHOW_HELP=true
            shift
            ;;
        --namespace|-n)
            [[ $# -lt 2 ]] && { echo -e "${RED}Error: $1 requires a value${NC}"; exit 1; }
            NAMESPACE="$2"
            shift 2
            ;;
        --output-dir|-o)
            [[ $# -lt 2 ]] && { echo -e "${RED}Error: $1 requires a value${NC}"; exit 1; }
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --tasks|-t)
            [[ $# -lt 2 ]] && { echo -e "${RED}Error: $1 requires a value${NC}"; exit 1; }
            TASKS="$2"
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
    - oc: OpenShift CLI
    - kubectl with ka plugin (kubearchive)
    - jq: JSON processor
    - podman: Container management tool

    Install: dnf install oc jq podman
    kubectl ka: https://kubearchive.github.io/kubearchive/main/cli/installation.html

USAGE:
    download-artifacts [PIPELINERUN] [OPTIONS]

ARGUMENTS:
    PIPELINERUN          Name of the PipelineRun (optional, will prompt if not provided)

OPTIONS:
    -n, --namespace NS   Kubernetes namespace (default: current context namespace)
    -o, --output-dir DIR Output directory (default: current directory)
    -t, --tasks TASKS    Task selection (comma-separated numbers or 'all')
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

    # Non-interactive with task selection
    /download-artifacts my-build-run --tasks 17
    /download-artifacts my-build-run -t 1,3,5
    /download-artifacts my-build-run -t all

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

fetch_pipelinerun() {
    local pr_name="$1"
    setup_kubearchive_host
    kubectl ka get pipelinerun "$pr_name" -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[0] // {}' || echo "{}"
}

fetch_taskrun() {
    local taskrun_name="$1"
    setup_kubearchive_host
    kubectl ka get taskrun "$taskrun_name" -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[0] // {}' || echo "{}"
}

# Check required tools
check_tools() {
    local missing=()
    for tool in oc kubectl jq podman; do
        command -v "$tool" &>/dev/null || missing+=("$tool")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing[*]}  (dnf install ${missing[*]})"
        exit 1
    fi
    if ! kubectl ka version &>/dev/null; then
        error "kubectl ka plugin not installed — https://kubearchive.github.io/kubearchive/main/cli/installation.html"
        exit 1
    fi
}

# Check if logged in
check_login() {
    if ! oc whoami &> /dev/null; then
        error "Not logged into any cluster"
        echo "Please run: oc login <cluster-api-url>"
        exit 1
    fi

    local current_cluster
    current_cluster=$(oc config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "unknown")
    info "Using cluster: $current_cluster"
}

# Get namespace
get_namespace() {
    if [[ -z "$NAMESPACE" ]]; then
        NAMESPACE=$(oc config view --minify -o jsonpath='{..namespace}' 2>/dev/null || echo "")
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
        server=$(oc config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "")
        if [[ -n "$server" ]]; then
            local cluster_domain
            cluster_domain=$(echo "$server" | sed -E 's|^.*api\.?(.*):[0-9]+$|\1|')
            export KUBECTL_PLUGIN_KA_HOST="https://kubearchive-api-server-product-kubearchive.apps.${cluster_domain}"
        fi
    fi

    _KUBEARCHIVE_SETUP_DONE=1
}

list_pipelineruns() {
    info "Fetching PipelineRuns from kubearchive..."
    setup_kubearchive_host

    local archived_prs
    archived_prs=$(kubectl ka get pipelinerun -n "$NAMESPACE" --limit 50 -o json 2>/dev/null || echo "")

    local pr_data=""
    if [[ -n "$archived_prs" ]]; then
        pr_data=$(echo "$archived_prs" | jq -r '.items[]? |
            "\(.metadata.name)|\(.status.conditions[0]?.reason // "Unknown")|\(.metadata.creationTimestamp)"' 2>/dev/null || echo "")
    fi

    if [[ -z "$pr_data" ]]; then
        error "No PipelineRuns found in kubearchive for namespace $NAMESPACE"
        exit 1
    fi

    pr_data=$(echo "$pr_data" | sort -t'|' -k3 -r | head -20)

    echo ""
    echo "Recent PipelineRuns:"
    echo "-------------------"

    local idx=1
    declare -g -A PR_MAP
    while IFS='|' read -r name status timestamp; do
        [[ -z "$name" ]] && continue
        PR_MAP[$idx]="$name"
        format_pr_line "$idx" "$name" "$status" "$timestamp"
        idx=$((idx + 1))
    done <<< "$pr_data"

    echo ""
    read -rp "Select PipelineRun number: " selection

    if [[ ! "$selection" =~ ^[0-9]+$ ]] || [[ -z "${PR_MAP[$selection]:-}" ]]; then
        error "Invalid selection"
        exit 1
    fi

    PIPELINERUN="${PR_MAP[$selection]}"
    success "Selected: $PIPELINERUN"
}

# Get PipelineRun details
get_pipelinerun_details() {
    info "Fetching PipelineRun details..."

    PR_JSON=$(fetch_pipelinerun "$PIPELINERUN")

    if [[ $(echo "$PR_JSON" | jq -r '.metadata.name // empty') != "$PIPELINERUN" ]]; then
        error "PipelineRun '$PIPELINERUN' not found"
        exit 1
    fi

    local pr_status
    pr_status=$(echo "$PR_JSON" | jq -r '.status.conditions[0].reason // "Unknown"')

    local completed_count total_count
    completed_count=$(echo "$PR_JSON" | jq -r '[.status.childReferences[]? | select(.kind == "TaskRun") | select(.pipelineTaskName != null)] | length')
    total_count=$(echo "$PR_JSON" | jq -r '[.spec.pipelineSpec.tasks[]?, .spec.pipelineSpec.finally[]?] | length')

    info "Pipeline status: $pr_status ($completed_count/$total_count tasks completed)"
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
    imagerepository=$(oc get imagerepository -n "$NAMESPACE" \
        -l "appstudio.redhat.com/component=$component" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$imagerepository" ]]; then
        warn "No ImageRepository found for component '$component'"
        return 1
    fi

    # Get pull secret name from ImageRepository
    local pull_secret
    pull_secret=$(oc get imagerepository "$imagerepository" -n "$NAMESPACE" \
        -o jsonpath='{.status.credentials.pull-secret}' 2>/dev/null || echo "")

    if [[ -z "$pull_secret" ]]; then
        warn "No pull secret found in ImageRepository '$imagerepository'"
        return 1
    fi

    # Get the dockerconfigjson from the secret
    local dockerconfig
    dockerconfig=$(oc get secret "$pull_secret" -n "$NAMESPACE" \
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
    declare -g -A TASKRUN_JSON_CACHE
    declare -A TASK_STATUS_MAP
    declare -A TASK_TASKRUNS  # Tracks all TaskRuns per task name

    while read -r ref; do
        local taskrun_name task_name
        taskrun_name=$(echo "$ref" | jq -r '.name')
        task_name=$(echo "$ref" | jq -r '.taskName')

        local status
        local taskrun_json
        taskrun_json=$(fetch_taskrun "$taskrun_name")
        TASKRUN_JSON_CACHE[$taskrun_name]="$taskrun_json"
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
        idx=$((idx + 1))
    done

    declare -g -a SELECTED_TASKS
    local selection="$TASKS"

    # If no tasks specified, prompt user
    if [[ -z "$selection" ]]; then
        echo ""
        echo "Enter task numbers (comma-separated, e.g., '1,3,5' or 'all'):"
        read -rp "> " selection
    fi

    if [[ "$selection" == "all" ]]; then
        for i in "${!TASK_MAP[@]}"; do
            SELECTED_TASKS+=("${TASK_MAP[$i]}")
        done
    else
        IFS=',' read -ra NUMS <<< "$selection"
        for num in "${NUMS[@]}"; do
            num="${num#"${num%%[![:space:]]*}"}"; num="${num%"${num##*[![:space:]]}"}"
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

# Resolve the best available auth file for OCI registry access
resolve_auth_file() {
    local temp_auth_file="${1:-}"
    if [[ -n "$temp_auth_file" ]]; then
        echo "$temp_auth_file"
    elif [[ -f "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/auth.json" ]]; then
        echo "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/auth.json"
    elif [[ -f "$HOME/.docker/config.json" ]]; then
        echo "$HOME/.docker/config.json"
    fi
}

# Download artifacts using podman
download_artifact() {
    local artifact_uri="$1"
    local output_path="$2"

    # Create output directory
    mkdir -p "$output_path"
    chmod 755 "$output_path"

    # Prepare credentials if available
    local temp_auth_file=""
    local temp_extract_dir=""
    local error_log=""
    _cleanup_download() {
        if [[ -n "${temp_extract_dir:-}" ]]; then rm -rf "$temp_extract_dir"; fi
        if [[ -n "${error_log:-}" ]]; then rm -f "$error_log"; fi
        if [[ -n "${temp_auth_file:-}" ]]; then rm -f "$temp_auth_file"; fi
    }
    trap _cleanup_download RETURN
    if [[ -n "${ARTIFACT_PULL_SECRET:-}" ]]; then
        temp_auth_file=$(mktemp)
        chmod 600 "$temp_auth_file"
        _TEMP_FILES+=("$temp_auth_file")
        echo "$ARTIFACT_PULL_SECRET" > "$temp_auth_file"
    fi

    local auth_file
    auth_file=$(resolve_auth_file "$temp_auth_file")

    temp_extract_dir=$(mktemp -d)
    local container_output="/tmp/output"
    [[ "$artifact_uri" != oci:* ]] && artifact_uri="oci:$artifact_uri"

    local auth_opts=()
    if [[ -n "$auth_file" ]]; then
        auth_opts=(-v "$auth_file:/home/notroot/.docker/config.json:z")
    fi

    error_log=$(mktemp)
    local podman_rc=0
    podman run --rm \
        ${auth_opts[@]+"${auth_opts[@]}"} \
        -v "$temp_extract_dir:$container_output:Z" \
        quay.io/konflux-ci/build-trusted-artifacts@sha256:90a188e90bf8f33cf93016bcfdfd0a3a9e7df6ff13691f001a0ed4f014060e2e \
        use "$artifact_uri=$container_output" 2>"$error_log" || podman_rc=$?

    if ls "$temp_extract_dir"/* &>/dev/null; then
        cp -r "$temp_extract_dir"/* "$output_path/" 2>/dev/null || true
        return 0
    fi

    local error_msg
    if [[ $podman_rc -eq 0 ]]; then
        error_msg="No files extracted from artifact (empty artifact layer?)"
    else
        error_msg=$(grep -E "(error|Error|failed|Failed|not found)" "$error_log" | head -2 | tr '\n' ' ' || true)
        [[ -z "$error_msg" ]] && error_msg="Authentication or network issue - artifacts may require cluster credentials"
    fi
    warn "Artifact download failed: $error_msg"
    return 1
}

# Download task logs (per-step)
download_task_logs() {
    local taskrun_name="$1"
    local taskrun_json="$2"
    local output_dir="$3"

    mkdir -p "$output_dir"

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

    local pod_name
    pod_name=$(echo "$taskrun_json" | jq -r '.status.podName // empty')

    if [[ -z "$pod_name" ]]; then
        warn "No pod name found in TaskRun"
        return 1
    fi

    setup_kubearchive_host

    while read -r step_name; do
        [[ -z "$step_name" ]] && continue

        local log_file="$output_dir/${step_name}.log"
        if kubectl ka logs "pod/$pod_name" -n "$NAMESPACE" -c "step-$step_name" > "$log_file" 2>/dev/null ||
           kubectl ka logs "pod/$pod_name" -n "$NAMESPACE" -c "$step_name" > "$log_file" 2>/dev/null; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
            rm -f "$log_file"
        fi
    done <<< "$steps"

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

    local taskrun_json="${TASKRUN_JSON_CACHE[$taskrun_name]}"

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
            # Remove empty artifact directories (e.g. empty artifact layers)
            if [[ -d "$artifact_dir" ]] && ! find "$artifact_dir" -type f -print -quit | grep -q .; then
                rm -rf "$artifact_dir"
            fi
        done <<< "$artifact_data"
    fi

    # Always download logs
    if download_task_logs "$taskrun_name" "$taskrun_json" "$task_dir"; then
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
        task_num=$((task_num + 1))
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

    # Iterate in the same order as SELECTED_TASKS to maintain consistency
    for task_name in "${SELECTED_TASKS[@]}"; do
        case "${DOWNLOAD_RESULTS[$task_name]:-unknown}" in
            success-both)
                success_both=$((success_both + 1))
                success "$task_name (artifacts + logs)"
                ;;
            success-artifacts)
                success_artifacts=$((success_artifacts + 1))
                warn "$task_name (artifacts only, no logs)"
                ;;
            success-logs)
                success_logs=$((success_logs + 1))
                warn "$task_name (logs only, no artifacts)"
                ;;
            failed)
                failed=$((failed + 1))
                error "$task_name (failed)"
                ;;
            *)
                failed=$((failed + 1))
                error "$task_name (unknown status)"
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
        read -rp "Overwrite? [y/N]: " confirm
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
