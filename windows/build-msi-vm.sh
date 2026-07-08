#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: build-msi-vm.sh OPTIONS

Required options:
  --repo-root DIR
  --vm-host HOST
  --target-conan-profile PROFILE
  --build-conan-profile PROFILE

Optional options:
  --vm-user USER                 Defaults to Administrator.
  --vm-jump HOST                 SSH ProxyJump host.
  --vm-password-env NAME         Environment variable containing the VM password.
                                 Defaults to WINDOWS_VM_PASSWORD.
  --vm-work-dir WINDOWS_PATH     Defaults to C:\Dev\eyebrow-msi-build.
  --output-dir DIR               Defaults to build/windows-vm-msi under the repo.
  --build-mode MODE              Defaults to DEV.
  --build-product PRODUCT        Defaults to ENTERPRISE.
  --concurrency N                Defaults to 12.
  --bootstrap-tools              Install missing build tools with winget.
  --artifactory-tunnel           Forward internal Artifactory through SSH.
  --copy-conan-credentials       Temporarily use the local Conan credential DB.
EOF
}

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

REPO_ROOT=""
VM_HOST=""
VM_USER="Administrator"
VM_JUMP=""
VM_PASSWORD_ENV="WINDOWS_VM_PASSWORD"
VM_WORK_DIR='C:\Dev\eyebrow-msi-build'
OUTPUT_DIR=""
TARGET_CONAN_PROFILE=""
BUILD_CONAN_PROFILE=""
BUILD_MODE="DEV"
BUILD_PRODUCT="ENTERPRISE"
CONCURRENCY="12"
BOOTSTRAP_TOOLS="false"
ARTIFACTORY_TUNNEL="false"
ARTIFACTORY_HOST="artifactory.ci.gitops.1keyes.net"
ARTIFACTORY_TUNNEL_PORT="443"
COPY_CONAN_CREDENTIALS="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-root) REPO_ROOT="${2:?Missing value for $1}"; shift 2 ;;
        --vm-host) VM_HOST="${2:?Missing value for $1}"; shift 2 ;;
        --vm-user) VM_USER="${2:?Missing value for $1}"; shift 2 ;;
        --vm-jump) VM_JUMP="${2:?Missing value for $1}"; shift 2 ;;
        --vm-password-env) VM_PASSWORD_ENV="${2:?Missing value for $1}"; shift 2 ;;
        --vm-work-dir) VM_WORK_DIR="${2:?Missing value for $1}"; shift 2 ;;
        --output-dir) OUTPUT_DIR="${2:?Missing value for $1}"; shift 2 ;;
        --target-conan-profile) TARGET_CONAN_PROFILE="${2:?Missing value for $1}"; shift 2 ;;
        --build-conan-profile) BUILD_CONAN_PROFILE="${2:?Missing value for $1}"; shift 2 ;;
        --build-mode) BUILD_MODE="${2:?Missing value for $1}"; shift 2 ;;
        --build-product) BUILD_PRODUCT="${2:?Missing value for $1}"; shift 2 ;;
        --concurrency) CONCURRENCY="${2:?Missing value for $1}"; shift 2 ;;
        --bootstrap-tools) BOOTSTRAP_TOOLS="true"; shift ;;
        --artifactory-tunnel) ARTIFACTORY_TUNNEL="true"; shift ;;
        --copy-conan-credentials) COPY_CONAN_CREDENTIALS="true"; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -z "${REPO_ROOT}" || -z "${VM_HOST}" || -z "${TARGET_CONAN_PROFILE}" || -z "${BUILD_CONAN_PROFILE}" ]]; then
    usage >&2
    exit 2
fi
if [[ "${TARGET_CONAN_PROFILE}" != windows-x86-* ]]; then
    echo "Windows VM MSI packaging currently supports x86 profiles only: ${TARGET_CONAN_PROFILE}" >&2
    exit 2
fi
if [[ "${VM_WORK_DIR}" == *" "* ]]; then
    echo "--vm-work-dir must not contain spaces: ${VM_WORK_DIR}" >&2
    exit 2
fi
if [[ -z "${OUTPUT_DIR}" ]]; then
    OUTPUT_DIR="${REPO_ROOT}/build/windows-vm-msi"
fi

password="${!VM_PASSWORD_ENV:-}"
ssh_command=(ssh)
scp_command=(scp)
if [[ -n "${password}" ]]; then
    if ! command -v sshpass >/dev/null 2>&1; then
        echo "sshpass is required when ${VM_PASSWORD_ENV} is set." >&2
        exit 1
    fi
    ssh_command=(sshpass -e ssh)
    scp_command=(sshpass -e scp)
fi

ssh_options=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
if [[ -n "${VM_JUMP}" ]]; then
    ssh_options+=(-o "ProxyJump=${VM_JUMP}")
fi

conan_home="${CONAN_USER_HOME:-${HOME}}"
profile_directory="${conan_home}/.conan/profiles"
for profile in "${TARGET_CONAN_PROFILE}" "${BUILD_CONAN_PROFILE}"; do
    if [[ ! -f "${profile_directory}/${profile}" ]]; then
        echo "Missing local Conan profile: ${profile_directory}/${profile}" >&2
        exit 1
    fi
done

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/eyebrow-windows-msi.XXXXXX")"
trap 'rm -rf "${temporary_directory}"' EXIT

archive_path="${temporary_directory}/eyebrow-source.tar.gz"
unpatched_archive_path="${temporary_directory}/eyebrow-source-unpatched.tar.gz"
staged_source_directory="${temporary_directory}/eyebrow-source"
staged_profiles="${temporary_directory}/profiles"
staged_conan_config="${temporary_directory}/conan-config"
mkdir -p \
    "${staged_source_directory}" \
    "${staged_profiles}" \
    "${staged_conan_config}" \
    "${OUTPUT_DIR}"
cp "${profile_directory}/${TARGET_CONAN_PROFILE}" "${staged_profiles}/"
cp "${profile_directory}/${BUILD_CONAN_PROFILE}" "${staged_profiles}/"

for conan_config_file in settings.yml remotes.json conan.conf cacert.pem artifacts.properties; do
    if [[ -f "${conan_home}/.conan/${conan_config_file}" ]]; then
        cp "${conan_home}/.conan/${conan_config_file}" "${staged_conan_config}/"
    fi
done
if [[ ! -f "${staged_conan_config}/settings.yml" ]]; then
    echo "Missing local Conan settings: ${conan_home}/.conan/settings.yml" >&2
    exit 1
fi
if [[ -d "${conan_home}/.conan/hooks" ]]; then
    cp -R "${conan_home}/.conan/hooks" "${staged_conan_config}/"
fi

staged_conan_credentials=""
if [[ "${COPY_CONAN_CREDENTIALS}" == "true" ]]; then
    local_conan_credentials="${conan_home}/.conan/.conan.db"
    if [[ ! -f "${local_conan_credentials}" ]]; then
        echo "Missing local Conan credential database: ${local_conan_credentials}" >&2
        exit 1
    fi
    staged_conan_credentials="${temporary_directory}/conan-credentials.db"
    cp "${local_conan_credentials}" "${staged_conan_credentials}"
fi

echo "Archiving current working tree..."
COPYFILE_DISABLE=1 tar -czf "${unpatched_archive_path}" \
    --exclude './.git' \
    --exclude './.cache' \
    --exclude './.mypy_cache' \
    --exclude './.nox' \
    --exclude './.ruff_cache' \
    --exclude './.venv' \
    --exclude '^./build' \
    --exclude '^./build/*' \
    --exclude '^./build-*' \
    --exclude '^./build-*/*' \
    --exclude './e2e' \
    --exclude './eyebrow-linux-build' \
    -C "${REPO_ROOT}" .
tar -xzf "${unpatched_archive_path}" -C "${staged_source_directory}"
patch -d "${staged_source_directory}" -p1 \
    < "${SCRIPT_DIR}/patches/eyebrow-windows-build.patch"
COPYFILE_DISABLE=1 tar -czf "${archive_path}" -C "${staged_source_directory}" .

remote_work_dir_scp="${VM_WORK_DIR//\\//}"
remote_profiles="${VM_WORK_DIR}\\profiles"
remote_conan_config="${VM_WORK_DIR}\\conan-config"
remote_archive="${VM_WORK_DIR}\\eyebrow-source.tar.gz"
remote_script="${VM_WORK_DIR}\\build-msi.ps1"
remote_conan_credentials="${VM_WORK_DIR}\\conan-credentials.db"

run_ssh() {
    if [[ -n "${password}" ]]; then
        SSHPASS="${password}" "${ssh_command[@]}" "${ssh_options[@]}" "${VM_USER}@${VM_HOST}" "$@"
    else
        "${ssh_command[@]}" "${ssh_options[@]}" "${VM_USER}@${VM_HOST}" "$@"
    fi
}

run_scp() {
    if [[ -n "${password}" ]]; then
        SSHPASS="${password}" "${scp_command[@]}" "${ssh_options[@]}" "$@"
    else
        "${scp_command[@]}" "${ssh_options[@]}" "$@"
    fi
}

echo "Preparing ${VM_USER}@${VM_HOST}:${VM_WORK_DIR}..."
run_ssh "powershell.exe -NoProfile -NonInteractive -Command \"New-Item -ItemType Directory -Force -Path '${VM_WORK_DIR}','${remote_profiles}' | Out-Null\""

echo "Uploading source and build inputs..."
run_scp "${archive_path}" "${VM_USER}@${VM_HOST}:${remote_work_dir_scp}/eyebrow-source.tar.gz"
run_scp "${SCRIPT_DIR}/build-msi.ps1" "${VM_USER}@${VM_HOST}:${remote_work_dir_scp}/build-msi.ps1"
run_scp "${staged_profiles}/${TARGET_CONAN_PROFILE}" "${VM_USER}@${VM_HOST}:${remote_work_dir_scp}/profiles/${TARGET_CONAN_PROFILE}"
run_scp "${staged_profiles}/${BUILD_CONAN_PROFILE}" "${VM_USER}@${VM_HOST}:${remote_work_dir_scp}/profiles/${BUILD_CONAN_PROFILE}"
run_scp -r "${staged_conan_config}" "${VM_USER}@${VM_HOST}:${remote_work_dir_scp}/"
if [[ -n "${staged_conan_credentials}" ]]; then
    run_scp "${staged_conan_credentials}" "${VM_USER}@${VM_HOST}:${remote_work_dir_scp}/conan-credentials.db"
fi

echo "Building the x86 MSI on the Windows VM..."
remote_build_command=(
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${remote_script}"
    -ArchivePath "${remote_archive}"
    -ProfileDirectory "${remote_profiles}"
    -ConanConfigDirectory "${remote_conan_config}"
    -TargetConanProfile "${TARGET_CONAN_PROFILE}"
    -BuildConanProfile "${BUILD_CONAN_PROFILE}"
    -WorkDirectory "${VM_WORK_DIR}"
    -BuildMode "${BUILD_MODE}"
    -BuildProduct "${BUILD_PRODUCT}"
    -Concurrency "${CONCURRENCY}"
)
if [[ "${BOOTSTRAP_TOOLS}" == "true" ]]; then
    remote_build_command+=(-BootstrapTools)
fi
if [[ -n "${staged_conan_credentials}" ]]; then
    remote_build_command+=(-ConanCredentialDatabase "${remote_conan_credentials}")
fi
if [[ "${ARTIFACTORY_TUNNEL}" == "true" ]]; then
    remote_build_command+=(
        -ArtifactoryTunnelHost "${ARTIFACTORY_HOST}"
        -ArtifactoryTunnelPort "${ARTIFACTORY_TUNNEL_PORT}"
    )
    if [[ -n "${password}" ]]; then
        SSHPASS="${password}" "${ssh_command[@]}" "${ssh_options[@]}" \
            -o ExitOnForwardFailure=yes \
            -R "127.0.0.1:${ARTIFACTORY_TUNNEL_PORT}:${ARTIFACTORY_HOST}:443" \
            "${VM_USER}@${VM_HOST}" "${remote_build_command[@]}"
    else
        "${ssh_command[@]}" "${ssh_options[@]}" \
            -o ExitOnForwardFailure=yes \
            -R "127.0.0.1:${ARTIFACTORY_TUNNEL_PORT}:${ARTIFACTORY_HOST}:443" \
            "${VM_USER}@${VM_HOST}" "${remote_build_command[@]}"
    fi
else
    run_ssh "${remote_build_command[@]}"
fi

run_scp "${VM_USER}@${VM_HOST}:${remote_work_dir_scp}/artifacts/artifact.msi" "${OUTPUT_DIR}/artifact.msi"
run_scp "${VM_USER}@${VM_HOST}:${remote_work_dir_scp}/artifacts/artifact-name.txt" "${OUTPUT_DIR}/artifact-name.txt"

artifact_name="$(tr -d '\r\n' < "${OUTPUT_DIR}/artifact-name.txt")"
if [[ -z "${artifact_name}" || "${artifact_name}" == */* || "${artifact_name}" == *\\* ]]; then
    echo "The Windows VM returned an invalid artifact name: ${artifact_name}" >&2
    exit 1
fi
mv "${OUTPUT_DIR}/artifact.msi" "${OUTPUT_DIR}/${artifact_name}"
echo "MSI copied to ${OUTPUT_DIR}/${artifact_name}"
