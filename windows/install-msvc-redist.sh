#!/bin/bash

set -euo pipefail

destination="${1:-/opt/msvc-redist}"
work_directory="$(mktemp -d /tmp/msvc-redist.XXXXXX)"
trap 'rm -rf "${work_directory}"' EXIT

bundle="${work_directory}/vc_redist.x86.exe"
attached_cab="${work_directory}/attached.cab"
attached_directory="${work_directory}/attached"
runtime_directory="${work_directory}/runtime"

curl -fsSL https://aka.ms/vs/17/release/vc_redist.x86.exe -o "${bundle}"

python3 - "${bundle}" "${attached_cab}" <<'PY'
import pathlib
import sys

bundle = pathlib.Path(sys.argv[1]).read_bytes()
cabinet_offsets = []
offset = 0
while True:
    offset = bundle.find(b"MSCF", offset)
    if offset == -1:
        break
    cabinet_offsets.append(offset)
    offset += 4

if len(cabinet_offsets) < 2:
    raise RuntimeError("Could not locate the attached VC++ redistributable cabinet")

pathlib.Path(sys.argv[2]).write_bytes(bundle[cabinet_offsets[1] :])
PY

mkdir -p "${attached_directory}" "${runtime_directory}"
7z x -y "${attached_cab}" "-o${attached_directory}" >/dev/null

runtime_cab=""
for candidate in "${attached_directory}"/a*; do
    if 7z l "${candidate}" 2>/dev/null | grep -q 'vcruntime140.dll_x86'; then
        runtime_cab="${candidate}"
        break
    fi
done

if [[ -z "${runtime_cab}" ]]; then
    echo "Could not locate the VC++ x86 runtime cabinet" >&2
    exit 1
fi

7z x -y "${runtime_cab}" "-o${runtime_directory}" >/dev/null

crt_directory="${destination}/x86/Microsoft.VC143.CRT"
mkdir -p "${crt_directory}"
for runtime_dll in \
    concrt140.dll_x86 \
    msvcp140.dll_x86 \
    msvcp140_1.dll_x86 \
    msvcp140_2.dll_x86 \
    msvcp140_atomic_wait.dll_x86 \
    msvcp140_codecvt_ids.dll_x86 \
    vcruntime140.dll_x86 \
    vcruntime140_threads.dll_x86; do
    if [[ ! -f "${runtime_directory}/${runtime_dll}" ]]; then
        echo "Missing VC++ runtime payload: ${runtime_dll}" >&2
        exit 1
    fi
    cp "${runtime_directory}/${runtime_dll}" "${crt_directory}/${runtime_dll%_x86}"
done
