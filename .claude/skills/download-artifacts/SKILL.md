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
- **kubectl** with **ka** plugin - KubeArchive CLI for accessing PipelineRuns and logs
- **jq** - JSON processor for parsing Kubernetes resources
- **podman** - For downloading Trusted Artifacts from OCI registries

## How Claude Should Use This Skill

**IMPORTANT**: When invoking this skill from Claude, you must:

1. **Use the Skill tool** (preferred method):
   ```
   Skill tool with: skill="download-artifacts", args="<pipelinerun-name> --tasks <selection>"
   ```

2. **Or use absolute path with Bash tool**:
   ```bash
   bash /mnt/rpmbuild-pipeline/.claude/skills/download-artifacts/download-artifacts.sh <pipelinerun-name> --tasks 17
   ```

3. **Or change directory first** (requires parentheses for subshell):
   ```bash
   (cd /mnt/rpmbuild-pipeline/.claude/skills/download-artifacts && bash download-artifacts.sh <pipelinerun-name> --tasks 17)
   ```

**Non-interactive mode**: ALWAYS use the `--tasks` flag to avoid blocking on interactive prompts:

```bash
# Download specific task
bash /mnt/rpmbuild-pipeline/.claude/skills/download-artifacts/download-artifacts.sh <pipelinerun-name> --tasks 17

# Download multiple tasks  
bash /mnt/rpmbuild-pipeline/.claude/skills/download-artifacts/download-artifacts.sh <pipelinerun-name> --tasks 1,3,5

# Download all tasks
bash /mnt/rpmbuild-pipeline/.claude/skills/download-artifacts/download-artifacts.sh <pipelinerun-name> --tasks all
```

Without `--tasks`, the script will block waiting for stdin input.

### Common Mistakes to Avoid

❌ **WRONG** - cd doesn't persist:
```bash
cd /path && bash script.sh  # bash runs in original directory!
```

❌ **WRONG** - relative path from wrong directory:
```bash
bash download-artifacts.sh  # won't find script unless already in that directory
```

✅ **CORRECT** - use absolute path:
```bash
bash /mnt/rpmbuild-pipeline/.claude/skills/download-artifacts/download-artifacts.sh
```

✅ **CORRECT** - use subshell:
```bash
(cd /mnt/rpmbuild-pipeline/.claude/skills/download-artifacts && bash download-artifacts.sh)
```

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
# Fetch PipelineRuns from kubearchive
kubectl ka get pipelinerun --namespace <namespace> --limit 50

# Display up to 20 most recent with:
# - Name
# - Status (Succeeded/Failed/Running)
# - Creation timestamp
```

### Fetch PipelineRun Details

Get full PipelineRun JSON from kubearchive:

```bash
kubectl ka get pipelinerun <name> --namespace <namespace> -o json
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
2. Fetch each TaskRun individually: `kubectl ka get taskrun <name> -o json` and extract `.status.conditions[0].reason`
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
kubectl ka get taskrun <taskrun-name> -n <namespace> -o json
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

Get per-step logs from kubearchive:

```bash
kubectl ka logs pod/<pod-name> -n <namespace> -c step-<step-name> > <output>/<step-name>.log
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

### Non-interactive mode (pre-select tasks)
```bash
/download-artifacts my-run --tasks 17
/download-artifacts my-run -t 1,3,5
/download-artifacts my-run -t all
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
status=$(kubectl ka get taskrun "$taskrun_name" -o json | jq -r '.items[0].status.conditions[0].reason')
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

### "jq not found"
Install jq: https://jqlang.github.io/jq/download/

### "Artifact download failed"
1. Check if the artifact actually exists in the registry
2. Verify credentials are correct

### "Permission denied"
Verify kubearchive and cluster access:
```bash
# Test kubearchive connectivity
kubectl ka get pipelinerun --namespace <namespace> --limit 1

# Verify access for pull credentials (uses live cluster)
oc auth can-i get imagerepositories -n <namespace>
oc auth can-i get secrets -n <namespace>
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
