# AGENTS.md

## Project Overview

This is the (main/upstream) flavor of
the RPM Build Pipeline for Konflux. It builds RPM packages against RHEL/Fedora buildroots using Tekton pipelines. The pipeline supports multi-architecture builds (aarch64, ppc64le, s390x, x86_64, i686, ...) and hermetic (offline) builds. For details see [architecture](docs/architecture.md) and overall [docs](docs).

### Key Technologies
- **Tekton**: Pipeline orchestration (for used API version check each yaml file)
- **Mock**: RPM build tool running in Podman containers
- **MPC**: Multi-Platform Controller for architecture-native builds via SSH to remote VMs
- **Trusted Artifacts**: OCI-based artifact storage for sources, dependencies, and build results
- **environment-image**: Container image with Mock, dist-git-client, koji-client, and build scripts

## Development Workflow
### Linting and Testing
```bash
# Lint YAML files
yamllint -c .yamllint.conf .

# CI automatically runs when PRs are opened/updated at GitHub
```

### Local Build Testing
```bash
# Reproduce a Fedora rawhide package build locally
./test-konflux-build-locally <package-name>
```

### Comparing with Other Flavors
```bash
# Compare with other flavors (e.g. Fedora)
./diff-flavor.sh fedora
```

## Contribution Guidelines
Contribution guidelines are covered in [CONTRIBUTING.md](CONTRIBUTING.md)

### AI Attribution

Include Assisted-by: AGENT_NAME:MODEL_VERSION [TOOL1] [TOOL2] in commit messages and pull request descriptions when using AI tools.

### Code Style
- YAML files use **2-space indentation** (enforced by .yamllint.conf)
- Use the single shared **environment-image** for all tasks rather than creating new images. It lives [in this repo](https://github.com/konflux-ci/rpmbuild-pipeline-environment-container)
- Tasks reusable by other pipelines belong in [build-definitions repo](https://github.com/konflux-ci/build-definitions)
- RPM-specific tasks belong in the `task/` directory
- Keep YAML formatting compatible with Renovate bot for automatic dependency updates

### CI Requirements
All pull requests must keep CI green. Multiple sample RPM packages are built on every PR to verify changes.

## Task Parameter Conventions
### Common Parameters
For parameters always check the pipeline/build-rpm-package.yaml, task definitions at task/ and docs/.

### Artifact Passing
Tasks use Trusted Artifacts to pass data between each other:
- `source-artifact`: Git repository source
- `dependencies-artifact`: Source files + spec file (from process-sources)
- `calculation-artifact`: Lockfile with build dependencies (from calculate-deps)
- `rpmbuild-artifact`: Built RPMs and logs (from rpmbuild)

## Multi-Architecture Builds

Builds run on native architecture VMs (not emulated). The pipeline task runs in x86_64 pods but uses MPC to SSH into architecture-native VMs for actual RPM builds. This ensures builds match production requirements (e.g., x86_64-v4 for RHEL 10).
