# Lookaside Cache Configuration

The RPM Build Pipeline records the lookaside cache configuration used to
download sources as a pipeline result called `LOOKASIDE_CONFIG`.  This allows
consumers to independently verify build inputs by reconstructing the exact
URLs that were used to fetch source tarballs.

## Retrieving LOOKASIDE_CONFIG from a build attestation

After a successful pipeline run, extract the configuration from the build
attestation:

Konflux currently produces SLSA v0.2 attestations.  Task results are stored
under `predicate.buildConfig.tasks[].results`:

```bash
cosign download attestation $IMAGE_URL | \
  jq -r '.payload' | base64 -d | \
  jq '.predicate.buildConfig.tasks[]
    | select(.results != null)
    | .results[]
    | select(.name == "LOOKASIDE_CONFIG")
    | .value' -r
```

Example output:

```json
{
  "package": "setup",
  "lookaside_location": "https://src.fedoraproject.org",
  "uri_pattern": "repo/pkgs/rpms/{name}/{filename}/{hashtype}/{hash}/{filename}"
}
```

## Reconstructing source download URLs

The `sources` file in the root of each dist-git repository lists every
source tarball with its hash.  For example, the `bash` package has:

```text
SHA512 (bash-5.3.tar.gz) = 05ef640e8ba011d10f858a270c626daa42ed5a75789d0298ae0ced9b2ebaf93d94d8ed5a211ac30cd34e82af8865e50024144c88a3c979bee7c38e449350e02e
SHA512 (bash-5.3.tar.gz.sig) = e9da98e993528d69bec9c6da272eb7a96858b4ba33487435f584c7df2d73c3ce82f373b5277cc3a7d8dc9ee04410dc06ce476d3f9ade097121bea0570abe07bc
```

Substitute the placeholders in `uri_pattern` using values from the
`sources` file and `LOOKASIDE_CONFIG`:

| Placeholder  | Source                       | Example            |
| ------------ | ---------------------------- | ------------------ |
| `{name}`     | `LOOKASIDE_CONFIG.package`   | `bash`             |
| `{filename}` | filename from sources file   | `bash-5.3.tar.gz`  |
| `{hashtype}` | hash prefix in sources file  | `sha512`           |
| `{hash}`     | hash value from sources file | `05ef640e8ba01...` |

The full download URL is `{lookaside_location}/{uri_pattern}` with
substitutions applied.  For the `bash` sources file above, this produces:

```text
https://src.fedoraproject.org/repo/pkgs/rpms/bash/bash-5.3.tar.gz/sha512/05ef640e8ba011d10f858a270c626daa42ed5a75789d0298ae0ced9b2ebaf93d94d8ed5a211ac30cd34e82af8865e50024144c88a3c979bee7c38e449350e02e/bash-5.3.tar.gz
https://src.fedoraproject.org/repo/pkgs/rpms/bash/bash-5.3.tar.gz.sig/sha512/e9da98e993528d69bec9c6da272eb7a96858b4ba33487435f584c7df2d73c3ce82f373b5277cc3a7d8dc9ee04410dc06ce476d3f9ade097121bea0570abe07bc/bash-5.3.tar.gz.sig
```

## Packages with no lookaside sources

Some packages (e.g., `setup`) ship all their source files directly in the
dist-git repository and have an empty or missing `sources` file.  The
`LOOKASIDE_CONFIG` result is still emitted for these builds — it reflects
the lookaside cache configuration that *would have been used*, not that
files were actually downloaded.  When consuming `LOOKASIDE_CONFIG`, check
whether the `sources` file has any entries before attempting to reconstruct
download URLs.  If it is empty, no tarballs were fetched from the
lookaside cache and all build inputs came from the repository itself.

## Scripted example

```bash
# Parse the LOOKASIDE_CONFIG
config=$(cosign download attestation "$IMAGE_URL" | \
  jq -r '.payload' | base64 -d | \
  jq -r '.predicate.buildConfig.tasks[]
    | select(.results != null)
    | .results[]
    | select(.name == "LOOKASIDE_CONFIG")
    | .value')

location=$(echo "$config" | jq -r '.lookaside_location')
pattern=$(echo "$config" | jq -r '.uri_pattern')
package=$(echo "$config" | jq -r '.package')

# For each entry in the sources file, construct the download URL
while IFS= read -r line; do
  hashtype=$(echo "$line" \
    | sed -E 's/^([A-Z0-9]+) .*/\1/' \
    | tr '[:upper:]' '[:lower:]')
  filename=$(echo "$line" \
    | sed -E 's/^[A-Z0-9]+ \(([^)]+)\).*/\1/')
  hash=$(echo "$line" | sed -E 's/.*= //')

  url="${location}/${pattern}"
  url="${url//\{name\}/$package}"
  url="${url//\{filename\}/$filename}"
  url="${url//\{hashtype\}/$hashtype}"
  url="${url//\{hash\}/$hash}"

  echo "$url"
done < sources
```

## Distribution examples

**Fedora** (`https://src.fedoraproject.org`):

```text
https://src.fedoraproject.org/repo/pkgs/rpms/bash/bash-5.3.tar.gz/sha512/{hash}/bash-5.3.tar.gz
```

**CentOS Stream** (`https://sources.stream.centos.org`):

```text
https://sources.stream.centos.org/sources/rpms/bash/bash-5.3.tar.gz/sha512/{hash}/bash-5.3.tar.gz
```

**Hummingbird** (`https://d1766whheab9hg.cloudfront.net`):

```text
https://d1766whheab9hg.cloudfront.net/rpms/bash/bash-5.3.tar.gz/sha512/{hash}/bash-5.3.tar.gz
```
