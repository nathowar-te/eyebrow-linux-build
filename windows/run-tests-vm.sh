#!/bin/bash

set -euo pipefail

repo_root=''
build_dir=''
configuration=''
timeout='600'
vm_host=''
vm_user='Administrator'
vm_jump=''
vm_password_env='WINDOWS_VM_PASSWORD'
vm_work_dir='C:\Dev\eyebrow-test-run'

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-root) repo_root="${2:?Missing value for $1}"; shift 2 ;;
        --build-dir) build_dir="${2:?Missing value for $1}"; shift 2 ;;
        --configuration) configuration="${2:?Missing value for $1}"; shift 2 ;;
        --timeout) timeout="${2:?Missing value for $1}"; shift 2 ;;
        --vm-host) vm_host="${2:?Missing value for $1}"; shift 2 ;;
        --vm-user) vm_user="${2:?Missing value for $1}"; shift 2 ;;
        --vm-jump) vm_jump="${2:?Missing value for $1}"; shift 2 ;;
        --vm-password-env) vm_password_env="${2:?Missing value for $1}"; shift 2 ;;
        --vm-work-dir) vm_work_dir="${2:?Missing value for $1}"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "${repo_root}" || -z "${build_dir}" || -z "${configuration}" || -z "${vm_host}" ]]; then
    echo 'Missing required Windows VM test runner argument.' >&2
    exit 2
fi

test_root="${repo_root}/${build_dir}"
registered_test_executables=()
while IFS= read -r test_executable; do
    registered_test_executables+=("${test_executable}")
done < <(
    find "${test_root}" -type f -name CTestTestfile.cmake -exec grep -h -F 'gtest_driver.py' {} + | \
        grep -F "/${configuration}/" | \
        sed -E 's/.*"([^" ]+\.exe)".*/\1/' | \
        sort -u
)
test_executables=()
for test_executable in "${registered_test_executables[@]}"; do
    local_test_executable="${test_executable}"
    if [[ "${local_test_executable}" == /build/* ]]; then
        local_test_executable="${repo_root}${local_test_executable#/build}"
    fi
    if [[ -f "${local_test_executable}" ]]; then
        test_executables+=("${local_test_executable}")
    fi
done
if [[ "${#test_executables[@]}" -eq 0 ]]; then
    echo "No compiled Windows GoogleTest executables were found under ${test_root}." >&2
    exit 1
fi

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/eyebrow-windows-tests.XXXXXX")"
trap 'rm -rf "${temporary_directory}"' EXIT
payload_directory="${temporary_directory}/payload"
mkdir -p "${payload_directory}"

for test_executable in "${test_executables[@]}"; do
    cp "${test_executable}" "${payload_directory}/"
    basename "${test_executable}" >> "${payload_directory}/tests.txt"
done
while IFS= read -r -d '' dependency; do
    cp -f "${dependency}" "${payload_directory}/"
done < <(
    find "${test_root}" -type f -path "*/${configuration}/*" -iname '*.dll' -print0
)

archive_path="${temporary_directory}/tests.tar.gz"
COPYFILE_DISABLE=1 tar -czf "${archive_path}" -C "${payload_directory}" .

password="${!vm_password_env:-}"
ssh_command=(ssh)
scp_command=(scp)
if [[ -n "${password}" ]]; then
    ssh_command=(sshpass -e ssh)
    scp_command=(sshpass -e scp)
fi
ssh_options=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
if [[ -n "${vm_jump}" ]]; then
    ssh_options+=(-o "ProxyJump=${vm_jump}")
fi

run_ssh() {
    if [[ -n "${password}" ]]; then
        SSHPASS="${password}" "${ssh_command[@]}" "${ssh_options[@]}" "${vm_user}@${vm_host}" "$@"
    else
        "${ssh_command[@]}" "${ssh_options[@]}" "${vm_user}@${vm_host}" "$@"
    fi
}

run_scp() {
    if [[ -n "${password}" ]]; then
        SSHPASS="${password}" "${scp_command[@]}" "${ssh_options[@]}" "$@"
    else
        "${scp_command[@]}" "${ssh_options[@]}" "$@"
    fi
}

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
remote_work_dir_scp="${vm_work_dir//\\//}"
remote_script="${vm_work_dir}\\run-tests.ps1"

run_ssh "powershell.exe -NoProfile -NonInteractive -Command \"New-Item -ItemType Directory -Force -Path '${vm_work_dir}' | Out-Null\""
run_scp "${archive_path}" "${vm_user}@${vm_host}:${remote_work_dir_scp}/tests.tar.gz"
run_scp "${script_directory}/run-tests.ps1" "${vm_user}@${vm_host}:${remote_work_dir_scp}/run-tests.ps1"

test_result=0
run_ssh powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -File "${remote_script}" -WorkDirectory "${vm_work_dir}" -TimeoutSeconds "${timeout}" || test_result=$?

result_directory="${repo_root}/${build_dir}/windows-test-results"
rm -rf "${result_directory}"
mkdir -p "${result_directory}"
run_scp "${vm_user}@${vm_host}:${remote_work_dir_scp}/test-results.tar.gz" \
    "${result_directory}/test-results.tar.gz"
tar -xzf "${result_directory}/test-results.tar.gz" -C "${result_directory}"

exit "${test_result}"
