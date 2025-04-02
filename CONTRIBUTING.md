# Contribution Guidelines

The **RPM Build Pipeline** is open source → see our [LICENSE](LICENSE).
**Contributions are welcome!**

This project hosts the [upstream][upstream] version of the pipeline.  Be aware
that other pipeline flavors exist (e.g., Fedora, CentOS, RHEL, and possibly
more, including custom or forked variants).  People from different environments
will often refer to this repository and try to stay in sync, and thus propose
patches.

If you're planning to implement or change something non-trivial (e.g., adding a
new parameter for shared use), **please open an issue first and start a
discussion**.  This helps ensure your idea benefits the broader community and
doesn't conflict with others' use cases.

## Pull Request Guidelines

Whenever a pull request is opened or updated in this repository, a sample RPM
package is built to verify that nothing breaks after (potentially) merging.

**Please make sure the CI stays green!**

## Code Organization & Style

Here are some important notes:

- Tasks that are reusable by other Pipelines should live in the
  [build-definitions repo][].  Tasks that are specific to this pipeline belong
  in the [/task](task) directory.
- The pipeline definition is in
  [`pipeline/build-rpm-package.yaml`](pipeline/build-rpm-package.yaml).
- YAML files use **2-space indentation**, including for dictionary values.
- This project uses external Tasks/Bundles → please keep the YAML formatting
  compatible with the [Renovate][] bot.

[upstream]: https://www.redhat.com/en/blog/what-open-source-upstream
[Renovate]: https://github.com/renovatebot/renovate
