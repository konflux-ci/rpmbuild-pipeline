# RPM Build Pipeline Parameters

Below is the set of supported parameters accepted by the pipeline.

| name                | description                                                                          | default value                       |
|---------------------|--------------------------------------------------------------------------------------|-------------------------------------|
| ociStorage          | Where the built artifacts and intermediate files are uploaded.                       |                                     |
| package-name        | The name of the package we want to build.                                            |                                     |
| git-url             | Source Repository URL. Typically set to `{{ source_url }}`.                          |                                     |
| revision            | Revision of the Source Repository. Typically use `{{ revision }}`.                   |                                     |
| target-branch       | What is the package branch we work with, e.g., `rhel-10-main`, `{{ target_branch }}` |                                     |
| build-architectures | Array of architectures we want to build for                                          | `[aarch64, s390x, ppc64le, x86_64]` |
| hermetic            | Perform the RPM build in a hermetic (offline) environment.                           | true                                |
| mock-image          | Mock Container image used to perform RPM builds in the pipeline.                     | Check the [main branch][mock-image] |
| specfile            | Specfile name. Default is null and package-name.spec is used.                        | null                                |
| monorepo-subdir      | Path to the RPM .spec file within the source tree. Relative to repo root. If a directory is provided, the `specfile` will be resolved within it. | "."                                |


## Parametrizing timeouts

There is a default [PipelineRun timeout][] for each Konflux instance (typically
2 hours).  You can extend/shorten it if needed.  The underlying rpmbuild tasks
are not a limiting factor, as they time out after 72 hours.


## Test-only parameters

These arguments are NOT meant to be used by end-users.  We use them internally
by the pipeline's CI.

| name                    | used in tasks |
| ---                     | ---           |
| self-ref-url            | process-sources, rpmbuild, upload-sbom |
| self-ref-revision       | process-sources, rpmbuild, upload-sbom |
| test-suffix             | import-to-quay |
| ociArtifactExpiresAfter | clone-repository, process-sources, calculate-deps, rpmbuild|


## Leftover parameters

These parameters are required by some of the tasks we depend on, but user
doesn't need to set them or anyhow maintain their values.  Often candidates for
removal in the future.

| name          | description | default value | used in tasks |
| ---           | ----        | ---           | ---           |
| rebuild       | ----        | ---           | init          |
| skip-checks   | ----        | ---           | init          |


[PipelineRun timeout]: https://tekton.dev/docs/pipelines/pipelineruns/#configuring-a-failure-timeout
[mock-image]: https://github.com/konflux-ci/rpmbuild-pipeline-environment-container
