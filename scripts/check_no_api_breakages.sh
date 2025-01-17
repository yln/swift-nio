#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

set -eu

# repodir
function all_modules() {
    local repodir="$1"
    (
    set -eu
    cd "$repodir"
    swift package dump-package | jq '.products |
                                     map(select(.type | has("library") )) |
                                     map(.name) | .[]' | tr -d '"'
    )
}

# repodir tag output
function build_and_do() {
    local repodir=$1
    local tag=$2
    local output=$3

    (
    cd "$repodir"
    git checkout "$tag" 2> /dev/null
    swift build
    while read -r module; do
        swift api-digester -dump-sdk -module "$module" \
            -o "$output/$module.json" -I "$repodir/.build/debug"
    done < <(all_modules "$repodir")
    )
}

function usage() {
    echo >&2 "Usage: $0 REPO-GITHUB-URL NEW-VERSION OLD-VERSIONS..."
    echo >&2
    echo >&2 "Example: "
    echo >&2 "  $0 https://github.com/apple/swift-nio master 2.1.1"
}

if [[ $# -lt 3 ]]; then
    usage
    exit 1
fi

tmpdir=$(mktemp -d /tmp/.check-api_XXXXXX)
repo_url=$1
new_tag=$2
shift 2

repodir="$tmpdir/repo"
git clone "$repo_url" "$repodir"
errors=0

for old_tag in "$@"; do
    mkdir "$tmpdir/api-old"
    mkdir "$tmpdir/api-new"

    echo "Checking public API breakages from $old_tag to $new_tag"

    build_and_do "$repodir" "$new_tag" "$tmpdir/api-new/"
    build_and_do "$repodir" "$old_tag" "$tmpdir/api-old/"

    for f in "$tmpdir/api-new"/*; do
        f=$(basename "$f")
        report="$tmpdir/$f.report"
        if [[ ! -f "$tmpdir/api-old/$f" ]]; then
            echo "NOTICE: NEW MODULE $f"
            continue
        fi

        echo -n "Checking $f... "
        swift api-digester -diagnose-sdk \
            --input-paths "$tmpdir/api-old/$f" -input-paths "$tmpdir/api-new/$f" 2>&1 \
            > "$report" 2>&1

        if ! shasum "$report" | grep -q cefc4ee5bb7bcdb7cb5a7747efa178dab3c794d5; then
            echo ERROR
            echo >&2 "=============================="
            echo >&2 "ERROR: public API change in $f"
            echo >&2 "=============================="
            cat >&2 "$report"
            errors=$(( errors + 1 ))
        else
            echo OK
        fi
    done
    rm -rf "$tmpdir/api-new" "$tmpdir/api-old"
done

if [[ "$errors" == 0 ]]; then
    echo "OK, all seems good"
fi
echo done
exit "$errors"
