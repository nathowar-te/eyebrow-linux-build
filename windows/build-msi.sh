#!/usr/bin/env bash

set -euo pipefail

build_dir="${1:?Usage: build-msi BUILD_DIR CONFIGURATION}"
configuration="${2:?Usage: build-msi BUILD_DIR CONFIGURATION}"
ninja_file="build-${configuration}.ninja"

commands="$(ninja -C "${build_dir}" -f "${ninja_file}" -t commands installer)"

find_command()
{
    local pattern="$1"
    local description="$2"
    local matches

    matches="$(printf '%s\n' "${commands}" | grep -F "${pattern}" || true)"
    if [[ -z "${matches}" || "$(printf '%s\n' "${matches}" | wc -l)" -ne 1 ]]; then
        echo "Expected exactly one ${description} command in ${ninja_file}." >&2
        exit 1
    fi

    printf '%s\n' "${matches}"
}

runtime_command="$(find_command 'generate_msvc_runtime_assembly.py' 'MSVC runtime generation')"
wix_command="$(find_command '/usr/local/bin/wix build' 'WiX build')"
post_process_command="$(find_command '.msi.post_build.stamp' 'MSI post-processing')"
wix_output="$(printf '%s\n' "${wix_command}" | sed -n 's/.* -out \([^ ]*\).*/\1/p')"

if [[ -z "${wix_output}" ]]; then
    echo "Could not determine the MSI output path from the generated WiX command." >&2
    exit 1
fi

/bin/bash -lc "${runtime_command}"

rm -f "${wix_output}"
for attempt in 1 2 3; do
    wix_status=0
    /bin/bash -lc "${wix_command}" || wix_status=$?

    msi_magic=""
    if [[ -s "${wix_output}" ]]; then
        msi_magic="$(od -An -tx1 -N8 "${wix_output}" | tr -d ' \n')"
    fi
    if [[ "${msi_magic}" == "d0cf11e0a1b11ae1" ]]; then
        if [[ "${wix_status}" -ne 0 ]]; then
            echo "WiX created a valid MSI despite Wine returning ${wix_status}." >&2
        fi
        break
    fi

    rm -f "${wix_output}"

    if [[ "${attempt}" -eq 3 ]]; then
        echo "WiX did not create ${wix_output} after ${attempt} attempts." >&2
        exit 1
    fi

    echo "WiX attempt ${attempt} failed; retrying..." >&2
done

/bin/bash -lc "${post_process_command}"
