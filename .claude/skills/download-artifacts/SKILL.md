---
name: download-artifacts
description: Download artifacts and logs from Konflux Tekton PipelineRuns with interactive task selection
trigger: Use when user needs to inspect build artifacts (RPMs, SBOMs) or logs from Konflux pipelines, or wants to download outputs from specific tasks
---

# Konflux Artifact Downloader

Download artifacts and logs from Konflux Tekton PipelineRuns, organizing them by task for easy debugging and inspection.

## What This Skill Does

1. **Connect** to Konflux cluster (uses existing `oc login` session)
2. **List** recent PipelineRuns or accept a specific PipelineRun name
3. **Show** available tasks with status (Succeeded/Failed/Running)
4. **Download** selected tasks' artifacts and logs
5. **Organize** output in `<pipelinerun>/<task>/` directory structure

## When to Use

- Need to inspect build artifacts (RPMs, SBOMs) from Konflux pipeline
- Want to download logs from specific tasks for debugging
- Need to compare artifacts across different builds
- Investigating pipeline failures and need detailed task outputs
- Want offline access to pipeline results

## Prerequisites

Required tools (skill checks automatically on startup):
- **oc** - Must be logged into cluster (`oc login <cluster>`)
- **kubectl** with **ka** plugin - KubeArchive CLI for accessing archived PipelineRuns
- **tkn** - Tekton CLI for log retrieval
- **jq** - JSON processor for parsing Kubernetes resources
- **podman** - For downloading Trusted Artifacts from OCI registries

## Instructions for Agent

### Tool Verification

Check all required tools are available:

```bash
# The skill's check_tools() function handles this automatically
# If tools are missing, it shows installation links and exits
```

### Authentication Check

Verify logged into cluster:

```bash
# The skill checks oc/kubectl whoami
# If not logged in, instructs user to run: oc login <cluster-url>
```

### Get PipelineRun Name

**If user provided PipelineRun name as argument**: Use it directly

**If no PipelineRun specified**: List recent PipelineRuns

```bash
# Fetch recent PipelineRuns from namespace
kubectl get pipelinerun -n <namespace> -o json

# Display up to 20 most recent with:
# - Name
# - Status (Succeeded/Failed/Running)
# - Creation timestamp

# Let user select by number or type 'a' to search kubearchive

# If no live PipelineRuns found, automatically try kubearchive (if installed):
kubectl ka get pipelinerun --namespace <namespace> --limit 50
```

**Kubearchive Support**:
- If no live PipelineRuns exist, the skill automatically checks kubearchive (if available)
- When selecting from live PipelineRuns, user can type 'a' or 'archive' to search archives instead
- Archived PipelineRuns are retrieved via: `kubectl ka get pipelinerun --namespace <ns>`
- All subsequent operations (TaskRun fetching, log download) work with archived resources

### Fetch PipelineRun Details

Get full PipelineRun JSON to extract task information:

```bash
# From live cluster
kubectl get pipelinerun <name> -n <namespace> -o json

# OR from kubearchive (for archived PipelineRuns)
kubectl ka get pipelinerun <name> --namespace <namespace>
```

### Parse TaskRuns

**IMPORTANT**: Use correct Tekton v1 API!

childReferences structure:
```yaml
status:
  childReferences:
  - name: taskrun-xyz
    kind: TaskRun
    pipelineTaskName: my-task
    # NO .status field here!
```

To get task status:

1. Extract TaskRun names from `.status.childReferences[]`
2. Fetch each TaskRun individually: `kubectl get taskrun <name> -o jsonpath='{.status.conditions[0].reason}'`
3. Group by task name (handle retries by preferring Succeeded status)

### Display Tasks for Selection

Show numbered list:
```
Available tasks:
----------------
 1) clone-repository              Succeeded
 2) process-sources               Succeeded
 3) rpmbuild-x86-64              Succeeded
 4) rpmbuild-aarch64             Failed
 5) check-noarch                 Succeeded
 6) show-summary                 Succeeded
```

Accept input:
- Comma-separated numbers: `1,3,5`
- `all` for everything

### Download Process

For each selected task:

#### 1. Download Artifacts

Get TaskRun results to find artifact URIs:

```bash
kubectl get taskrun <taskrun-name> -n <namespace> -o json
# Look in .status.results[] for entries where .name ends with "-artifact"
# Extract .value (the OCI artifact URI)
```

Download using podman with build-trusted-artifacts (handles both blob and manifest digests):

```bash
podman run --rm \
  -v <auth-file>:/run/containers/0/auth.json:ro \
  -v <output-path>:/tmp/output:Z \
  quay.io/konflux-ci/build-trusted-artifacts@sha256:90a188e90bf8f33cf93016bcfdfd0a3a9e7df6ff13691f001a0ed4f014060e2e \
  use <artifact-uri>=/tmp/output
```

#### 2. Download Logs

Get per-step logs:

```bash
# For live TaskRuns
# Get step names from TaskRun
kubectl get taskrun <name> -n <namespace> -o jsonpath='{.status.steps[*].name}'

# Download each step's log
tkn taskrun logs <taskrun-name> -n <namespace> -s <step-name> > <output>/<step-name>.log

# For archived TaskRuns (from kubearchive)
# Extract logs from .status.steps[].terminated.message field
# Note: Archived logs may be limited compared to live logs retrieved via tkn
kubectl ka get taskrun <name> --namespace <namespace> | \
  jq -r '.status.steps[] | select(.name == "<step-name>") | .terminated.message'
```

### Directory Structure

Organize downloads as:

```
<pipelinerun-name>/
  <task-name-1>/
    <artifact-name-1>/
      artifact-file.rpm
      artifact-file.sbom.json
    <artifact-name-2>/
      ...
    step-1.log
    step-2.log
  <task-name-2>/
    step-1.log
    step-2.log
```

**Important**: Each artifact result (e.g., `SOURCE_ARTIFACT`, `dependencies-artifact`, `rpmbuild-artifact`) is downloaded to its own subdirectory within the task directory. This keeps artifacts organized and prevents filename collisions.

### Error Handling

- **Continue on failures**: If one task fails to download, continue with remaining tasks
- **Track results**: Maintain success/failure count per task
- **Show summary**: At end, report what succeeded/failed

Example summary:
```
Downloaded 8/10 tasks successfully:
  ✓ rpmbuild-x86-64 (artifacts + logs)
  ✓ check-noarch (logs only, no artifacts)
  ✗ rpmbuild-i686 (artifact download failed)
  ✗ calculate-deps (TaskRun not found)
```

### Overwrite Protection

If output directory exists:
1. Warn user
2. Prompt: "Directory exists, overwrite? [y/N]"
3. Respect user choice (exit if N, remove and proceed if Y)

### Progress Feedback

Show simple progress during download:

```
ℹ Downloading task 3/10: rpmbuild-x86-64
✓ rpmbuild-x86-64 (artifacts + logs)
ℹ Downloading task 4/10: check-noarch
✓ check-noarch (logs only)
```

## Usage Examples

### Interactive mode (prompts for everything)
```bash
/download-artifacts
```

### Direct PipelineRun specification
```bash
/download-artifacts my-build-run-abc123
```

### With options
```bash
/download-artifacts my-build-run --namespace my-tenant --output-dir /tmp/builds
```

### Short flags
```bash
/download-artifacts my-run -n my-namespace -o ./artifacts
```

## Implementation Notes

### Correct Tekton API Usage

**WRONG** (will always return "Unknown"):
```jq
.status.childReferences[] | .status  # childReferences don't have .status!
```

**CORRECT**:
```bash
# Get TaskRun name from childReferences
taskrun_name=$(echo "$pr_json" | jq -r '.status.childReferences[] | select(.pipelineTaskName == "my-task") | .name')

# Fetch actual TaskRun to get status
status=$(kubectl get taskrun "$taskrun_name" -o jsonpath='{.status.conditions[0].reason}')
```

### Retry Handling

When tasks are retried, multiple TaskRuns exist for same task:
- Group TaskRuns by `.pipelineTaskName`
- Prefer TaskRuns with status "Succeeded"
- Fall back to most recent if none succeeded

### Artifact Format

Trusted Artifacts are stored as OCI artifacts:
- URI format: `oci://quay.io/redhat-user-workloads/.../package@sha256:digest`
- TaskRun results may contain blob digests or manifest digests
- The `build-trusted-artifacts` container handles both digest types

### Running State

If PipelineRun is still Running:
- Only show completed tasks (with status from their TaskRuns)
- User can download partial results
- Show clear indication: "Pipeline: Running (8/12 tasks completed)"

## Troubleshooting

### "Not logged into any cluster"
Run: `oc login <cluster-api-url>`

### "No PipelineRuns found"
Check namespace: `oc project` or use `-n` flag

If PipelineRuns have been archived, install kubectl ka:
```bash
# Install KubeArchive CLI plugin
# See: https://kubearchive.github.io/kubearchive/main/cli/installation.html

# Search for archived PipelineRuns
kubectl ka get pipelinerun --namespace <namespace>
```

### "tkn not found"
Install Tekton CLI: https://tekton.dev/docs/cli/

### "jq not found"
Install jq: https://jqlang.github.io/jq/download/

### "Artifact download failed"
1. Check if the artifact actually exists in the registry
2. Verify credentials are correct

### "Permission denied"
Verify cluster access:
```bash
oc auth can-i get pipelineruns -n <namespace>
oc auth can-i get taskruns -n <namespace>
```

## Script Location

The actual implementation script is:
`.claude/skills/download-artifacts/download-artifacts.sh`

It contains:
- All tool checking logic
- PipelineRun/TaskRun parsing with correct API usage
- Interactive selection menus
- Artifact download via podman
- Log download per step
- Progress display and error handling

Invoke it via the skill system, which handles argument passing and execution context.
