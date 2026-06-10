# Download Artifacts Skill

Download artifacts and logs from Konflux Tekton PipelineRuns.

## Features

- 🔍 **Interactive PipelineRun selection** - Browse recent runs or specify by name
- 📦 **Artifact download** - Retrieves Trusted Artifacts from OCI registries
- 📝 **Per-step logs** - Downloads individual logs for each task step
- ✅ **Smart retry handling** - Automatically uses latest TaskRun when tasks are retried
- 🎯 **Selective download** - Choose specific tasks or download all
- 📊 **Progress tracking** - See what's downloading in real-time
- 🔄 **Error resilience** - Continues downloading even if some tasks fail

## Requirements

### Required Tools

- **oc** or **kubectl** - Kubernetes/OpenShift CLI
  - Install: https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html
  - Default OS version is often not sufficient

- **tkn** - Tekton CLI
  - Install: https://tekton.dev/docs/cli/

- **jq** - JSON processor
  - Install: dnf install jq
  - Install: https://jqlang.github.io/jq/download/
  - Usually pre-installed on most Linux distributions

### Artifact Download Tools (one required)

- **oras** - OCI Registry As Storage CLI
  - Install: dnf install golang-oras
  - Install: https://oras.land/
  - Lightweight, purpose-built tool for OCI artifacts

- **podman** - Container management tool
  - Install: dnf install podman
  - Install: https://podman.io/
  - More widely available, especially in RHEL/Fedora environments
  - Used as fallback if oras is not available

## Usage

### Basic Usage

```bash
# Interactive mode - prompts for everything
/download-artifacts

# Download specific PipelineRun
/download-artifacts my-build-run-abc123

# Specify namespace and output directory
/download-artifacts my-build-run --namespace my-tenant --output-dir /tmp/builds

# Short flags
/download-artifacts my-build-run -n my-tenant -o ./artifacts
```

### Options

- `-n, --namespace NS` - Kubernetes namespace (default: current context namespace)
- `-o, --output-dir DIR` - Output directory (default: current directory)
- `-h, --help` - Show help message

### Authentication

You must be logged into the cluster before running:

```bash
oc login <cluster-api-url>
```

## Output Structure

```
<pipelinerun-name>/
  <task-name-1>/
    step-1.log
    step-2.log
    artifact-file-1.rpm
    artifact-file-2.rpm
  <task-name-2>/
    step-1.log
    step-2.log
  ...
```

## How It Works

1. **Authentication Check** - Verifies you're logged into a cluster
2. **Namespace Detection** - Uses current context or specified namespace
3. **PipelineRun Selection** - Lists recent runs or uses provided name
4. **Task Selection** - Shows interactive menu of available tasks
5. **Download**:
   - Parses PipelineRun JSON to find Trusted Artifact URIs
   - Downloads artifacts using `oras` (or `podman` fallback)
   - Downloads per-step logs using `tkn`
6. **Summary** - Reports success/failure for each task

## Task Selection

When prompted to select tasks, you can:

- Enter specific numbers: `1,3,5`
- Enter ranges: `1-5` (not yet implemented, enter manually)
- Enter `all` to download everything

## Error Handling

The skill continues downloading even if some tasks fail. At the end, you'll see a summary showing which tasks succeeded and which failed.

## Examples

### Download from specific namespace

```bash
/download-artifacts build-rpms-abc123 --namespace rhel-rpms-tenant
```

### Download to custom directory

```bash
/download-artifacts --output-dir ~/konflux-downloads
```

### Quick download of latest build

```bash
# Just run without arguments and select from menu
/download-artifacts
```

## Troubleshooting

### "Not logged into any cluster"

Run `oc login <cluster-api-url>` first.

### "No PipelineRuns found"

Check your namespace: `oc project` or specify with `-n`.

### "Artifact download failed"

Ensure you have either `oras` or `podman` installed. Check artifact URIs in the PipelineRun status.

### "Permission denied"

Verify you have access to the namespace and can read PipelineRuns:

```bash
oc auth can-i get pipelineruns -n <namespace>
```

## Implementation Details

- Uses `kubectl/oc` to query PipelineRun and TaskRun resources
- Parses JSON output with `jq` (bundled with most systems)
- Downloads Trusted Artifacts from OCI registries using:
  - Primary: `oras pull` (lightweight, purpose-built)
  - Fallback: `podman run` with `build-trusted-artifacts` image
- Downloads logs using `tkn taskrun logs -s <step>`
- Handles retried tasks by selecting latest successful TaskRun

## Contributing

This skill was created with assistance from Claude Code.

## License

Part of the Konflux RPM Build Pipeline project.
