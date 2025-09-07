#! /bin/bash

codedir=$(dirname "$(readlink -f "$0")")
other_flavors=$codedir/.other-flavors.sh

diff_flavor=$1

flavors+=( "fedora" )
fedora_raw_link=https://gitlab.com/fedora/infrastructure/konflux/rpmbuild-pipeline/-/raw/main
fedora_overrides=( "pipeline/build-rhel-package.yaml pipeline/build-rpm-package.yaml" )

test -f "$other_flavors" && source "$other_flavors"

case " ${flavors[*]} " in
    *" $diff_flavor "*)
        eval raw_link=\$$diff_flavor\_raw_link
        eval "overrides=( \"\${${diff_flavor}_overrides[@]}\" )"
        ;;
    *)
        echo "Missing argument, execute either of those:"
        for flavor in ${flavors[@]}; do
            echo "  $0 $flavor"
        done
        exit 1
        ;;
esac

set -x

TMPDIR=$(mktemp -d /tmp/compare-rpmbuild-pipeline-XXXXXX)

files_to_diff="
pipeline/build-rpm-package.yaml
task/calculate-deps.yaml
task/check-noarch.yaml
task/process-sources.yaml
task/import-to-quay.yaml
task/rpmbuild.yaml
renovate.json
diff-flavor.sh
"

for file in $files_to_diff; do
    url=$raw_link/$file
    for override in "${overrides[@]}"; do
        set -- $override
        if test "$1" == "$file"; then
            url=$raw_link/$2
            break
        fi
    done
    dest=$TMPDIR/$file
    (
        cd "$TMPDIR"
        mkdir -p "$(dirname "$file")"
    )
    curl "$url" > "$dest" 2>/dev/null
    vim -d "$file" "$dest"
done

