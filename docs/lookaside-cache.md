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
source tarball with its hash.  The current format is:

```text
SHA512 (glibc-2.39.tar.xz) = 476350092e854...
SHA512 (glibc-2.39-fedora.patch) = 8b0a02c1012...
```

Substitute the placeholders in `uri_pattern` using values from the
`sources` file and `LOOKASIDE_CONFIG`:

| Placeholder  | Source                       | Example              |
| ------------ | ---------------------------- | -------------------- |
| `{name}`     | `LOOKASIDE_CONFIG.package`   | `glibc`              |
| `{filename}` | filename from sources file   | `glibc-2.39.tar.xz` |
| `{hashtype}` | hash prefix in sources file  | `sha512`             |
| `{hash}`     | hash value from sources file | `476350092e854...`   |

The full download URL is `{lookaside_location}/{uri_pattern}` with
substitutions applied:

```text
https://src.fedoraproject.org/repo/pkgs/rpms/glibc/\
  glibc-2.39.tar.xz/sha512/476350092e854.../glibc-2.39.tar.xz
```

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
https://src.fedoraproject.org/repo/pkgs/rpms/glibc/\
  glibc-2.39.tar.xz/sha512/{hash}/glibc-2.39.tar.xz
```

**CentOS Stream** (`https://sources.stream.centos.org`):

```text
https://sources.stream.centos.org/sources/rpms/kernel/\
  linux-6.12.tar.xz/sha512/{hash}/linux-6.12.tar.xz
```

**Hummingbird** (`https://d1766whheab9hg.cloudfront.net`):

```text
https://d1766whheab9hg.cloudfront.net/rpms/glibc/\
  glibc-2.39.tar.xz/sha512/{hash}/glibc-2.39.tar.xz
```
