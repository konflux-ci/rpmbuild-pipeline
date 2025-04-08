# RPM Build Pipeline Architecture

In short, the RPM Build Pipeline builds on top of existing tooling that Fedora,
CentOS, and RHEL maintainers are familiar with—namely, it obtains source code
from [DistGit][] and builds using [Mock][].

This brings us a lot of convenience, because people can (continue to) work with
package Git repositories the way they are used to—and, for example, easily
reproduce builds locally.

People often ask why we use Mock in a "container-native" build system.  The
short answer is that Mock actually brings *a lot* of convenience.  And note
this: **Mock is a container-native tool** nowadays!  For more info, check the
[Why Mock][] document.


## Basic pipeline flow

The chart below illustrates the current Tekton Task flow used in the RPM Build
Pipeline.

```mermaid
graph TD

  clone_repository[clone-repository] --> get_sources[get-rpm-sources /from DistGit lookaside/]

  get_sources --> nosrpm_a[calculate-deps-x86_64]:::ARCH
  get_sources --> nosrpm_b[calculate-deps-aarch64]:::ARCH
  get_sources --> nosrpm_c[calculate-deps ...]:::ARCH

  nosrpm_a --> prefetch[Download BuildRequires.
    Pull Mock bootstrap.
    Prepare offline repositories.]
  prefetch --> build_a[rpmbuild-x86_64]:::ARCH

  nosrpm_b --> prefetch
  prefetch --> build_b[rpmbuild-aarch64]:::ARCH

  nosrpm_c --> prefetch
  prefetch --> build_c[rpmbuild ...]:::ARCH

  build_a --> Upload[upload-to-quay]
  build_b --> Upload
  build_c --> Upload

  Upload --> check_noarch[check-noarch]

  classDef ARCH fill:yellow
```

The yellow boxes represent architecture-specific tasks.  This means that, for
example, `rpmbuild-x86_64` Task must be executed in a native `x86_64`
environment.  Konflux needs to allocate a virtual machine for this task
using [MPC][].


## Steps

- **clone-repository**
    - This step is architecture-agnostic and is executed only once.
    - Typically, we clone the package source from a DistGit repository or a fork.
    - A full clone is required (to keep [rpmautospec][] happy).
- **get-rpm-sources**
    - Downloads source artifacts (e.g., source tarballs) from the corresponding
      DistGit instance.
- **calculate-deps-&lt;ARCH&gt; (Mock)**
    - This step **is not** [hermetic][].  However, it is necessary in order to
      build hermetically in the subsequent **rpmbuild-&lt;ARCH&gt;** step.
    - This step is architecture-specific (executed multiple times, for each
      selected architecture).
    - Starts `rpmbuild` (via Mock) to extract sources and calculate dynamic build
      requirements (see [%generate_buildrequires][]).
    - Generates a lockfile listing the required RPMs to be downloaded.
    - The lockfile is one of the sources artifacts used for producing SBOM.
- **Download BuildRequires, etc.**
    - Downloads RPMs listed in the lockfile to prepare a local, "offline" RPM repository.
    - **TODO**: While this step is not architecture-specific, it's currently bundled into
      the following `rpmbuild-*` steps.  It should be separated into its own
      pod-native task.
- **rpmbuild-&lt;ARCH&gt; (Mock)**
    - This step **is** [hermetic][].
    - Produces a list of "binary" RPMs (built artifacts).
- **upload-to-quay**
    - Collects all built artifacts from previous steps and uploads them to
      OCI registry (the destination is selected by the user as a pipeline
      parameter).
- **check-noarch**
    - Verifies that all noarch (sub-)packages from the architecture-specific
      builds are identical.  If they are not, the step fails the pipeline.
      Noarch sub-packages are built on all architectures, but typically, we want
      to de-duplicate and distribute only one of them.

[%generate_buildrequires]: https://github.com/rpm-software-management/mock/issues/1359
[MPC]: https://github.com/konflux-ci/multi-platform-controller
[rpmautospec]: https://github.com/fedora-infra/rpmautospec
[hermetic]: https://rpm-software-management.github.io/mock/feature-hermetic-builds
[Why Mock]: https://rpm-software-management.github.io/mock/Why-Mock
[Mock]: https://rpm-software-management.github.io/mock/
[DistGit]: https://github.com/release-engineering/dist-git
