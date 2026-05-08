#!/bin/bash

# Build an Ubuntu 22.04 Linux build container, then either open an interactive
# shell or run a configure + compile flow inside it. For IOx/Meraki builds,
# the Docker package step runs on the macOS host after the container build.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./start.sh [options]

Without --profile, opens an interactive shell in the build container.

Configure, compile, and package:
  ./start.sh \
    --profile linux-alpine322-meraki-arm64-clang21-debug \
    --build-conan-profile linux-ubuntu2204-arm64-gcc11-release \
    --linux-distro meraki

Options:
  --profile, --target-conan-profile PROFILE
      Conan target/host profile for the artifact being built.

  --build-conan-profile PROFILE
      Conan build profile for tools that execute inside the container.

  --linux-distro DISTRO
      Linux distro passed to configure.py, for example meraki or iox.

  --build-dir DIR
      Build directory inside the repo mount. Defaults to build/<linux-distro>.

  --build-mode MODE
      Build mode passed to configure.py. Defaults to DEV.

  --build-product PRODUCT
      Build product passed to configure.py. Defaults to ENTERPRISE.

  --concurrency N
      Parallel compile jobs. Defaults to 12.

  --target TARGET
      CMake target to build. Can be specified more than once. Defaults to all.
      For IOx/Meraki host packaging, package is built automatically as well.

  --build-arch ARCH
      Docker package architecture, arm64 or amd64. Defaults from --profile.

  --conan-build-packages VALUE
      Passes -DTE_CONAN_BUILD_PACKAGES=<VALUE>, for example "missing".

  --skip-host-package
      Do not run scripts/docker/package.py on the host after the container build.

  --no-fresh
      Do not pass --fresh to configure.py.

  --help
      Show this help.
EOF
}

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "${DIR}/../" && pwd )"

TARGET_CONAN_PROFILE=""
BUILD_CONAN_PROFILE=""
LINUX_DISTRO=""
BUILD_DIR=""
BUILD_MODE="DEV"
BUILD_PRODUCT="ENTERPRISE"
CONCURRENCY="12"
CONAN_BUILD_PACKAGES=""
FRESH="true"
BUILD_TARGETS=()
BUILD_ARCH=""
HOST_PACKAGE="true"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile|--target-conan-profile|--target_conan_profile)
            TARGET_CONAN_PROFILE="${2:?Missing value for $1}"
            shift 2
            ;;
        --build-conan-profile|--build_conan_profile)
            BUILD_CONAN_PROFILE="${2:?Missing value for $1}"
            shift 2
            ;;
        --linux-distro|--linux_distro)
            LINUX_DISTRO="${2:?Missing value for $1}"
            shift 2
            ;;
        --build-dir|--build_dir)
            BUILD_DIR="${2:?Missing value for $1}"
            shift 2
            ;;
        --build-mode|--build_mode)
            BUILD_MODE="${2:?Missing value for $1}"
            shift 2
            ;;
        --build-product|--build_product)
            BUILD_PRODUCT="${2:?Missing value for $1}"
            shift 2
            ;;
        --concurrency)
            CONCURRENCY="${2:?Missing value for $1}"
            shift 2
            ;;
        --target)
            BUILD_TARGETS+=("${2:?Missing value for $1}")
            shift 2
            ;;
        --build-arch|--build_arch)
            BUILD_ARCH="${2:?Missing value for $1}"
            shift 2
            ;;
        --conan-build-packages|--conan_build_packages)
            CONAN_BUILD_PACKAGES="${2:?Missing value for $1}"
            shift 2
            ;;
        --skip-host-package)
            HOST_PACKAGE="false"
            shift
            ;;
        --no-fresh)
            FRESH="false"
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -z "${TARGET_CONAN_PROFILE}" && -z "${BUILD_CONAN_PROFILE}" && -z "${LINUX_DISTRO}" ]]; then
    RUN_MODE="shell"
else
    RUN_MODE="build"
    if [[ -z "${TARGET_CONAN_PROFILE}" || -z "${BUILD_CONAN_PROFILE}" || -z "${LINUX_DISTRO}" ]]; then
        echo "Configure/build mode requires --profile, --build-conan-profile, and --linux-distro." >&2
        usage >&2
        exit 2
    fi
fi

if [[ -z "${BUILD_DIR}" ]]; then
    BUILD_DIR="build/${LINUX_DISTRO:-linux}"
fi

if [[ "${#BUILD_TARGETS[@]}" -eq 0 ]]; then
    BUILD_TARGETS=(all)
fi

if [[ -z "${BUILD_ARCH}" ]]; then
    case "${TARGET_CONAN_PROFILE}" in
        *-x64-*|*x86_64*)
            BUILD_ARCH="amd64"
            ;;
        *-arm64-*|*armv8*)
            BUILD_ARCH="arm64"
            ;;
        *)
            BUILD_ARCH="arm64"
            ;;
    esac
fi

if [[ "${BUILD_ARCH}" != "arm64" && "${BUILD_ARCH}" != "amd64" ]]; then
    echo "--build-arch must be arm64 or amd64, got: ${BUILD_ARCH}" >&2
    exit 2
fi

container_build_targets=("${BUILD_TARGETS[@]}")
if [[ "${HOST_PACKAGE}" == "true" && ( "${LINUX_DISTRO}" == "iox" || "${LINUX_DISTRO}" == "meraki" ) ]]; then
    has_package_target="false"
    for target in "${container_build_targets[@]}"; do
        if [[ "${target}" == "package" ]]; then
            has_package_target="true"
            break
        fi
    done
    if [[ "${has_package_target}" == "false" ]]; then
        container_build_targets+=(package)
    fi
fi

echo "Repository root: ${REPO_ROOT}"

# Create a directory for the agent logs.
LOGDIR="${DIR}/logs"
mkdir -p "${LOGDIR}"

requirements_context="$(mktemp -d "${TMPDIR:-/tmp}/eyebrow-linux-build-requirements.XXXXXX")"
cp "${REPO_ROOT}/scripts/requirements.txt" "${requirements_context}/requirements.txt"

# Build the image. Use an iidfile instead of quiet stdout capture so Docker's
# progress output remains visible while still giving us the image ID afterward.
iidfile="$(mktemp "${TMPDIR:-/tmp}/eyebrow-linux-build-image.XXXXXX")"
trap 'rm -f "${iidfile}"; rm -rf "${requirements_context}"' EXIT
docker build \
    --network=host \
    --allow network.host \
    --build-context python_requirements="${requirements_context}" \
    --iidfile "${iidfile}" \
    "${DIR}"
image="$(<"${iidfile}")"

echo "Using image: ${image}"

docker_run_args=(
    --rm
    --privileged
    -v "${REPO_ROOT}:/build"
    -v "${HOME}/.conan:/root/.conan"
    -v "${HOME}/.ssh:/root/.ssh"
    -v "${LOGDIR}:/var/log"
    -w /build
    --cap-add NET_ADMIN
)

if [[ "${RUN_MODE}" == "shell" ]]; then
    docker run -it "${docker_run_args[@]}" "${image}"
    exit 0
fi

container_script=$(cat <<EOF
set -euo pipefail

source /venv/bin/activate

configure_args=(
    --build_dir "${BUILD_DIR}"
    --build_mode "${BUILD_MODE}"
    --build_product "${BUILD_PRODUCT}"
    --profile "${TARGET_CONAN_PROFILE}"
    --build_conan_profile "${BUILD_CONAN_PROFILE}"
    --linux_distro "${LINUX_DISTRO}"
)

if [[ "${FRESH}" == "true" ]]; then
    configure_args+=(--fresh)
fi

if [[ -n "${CONAN_BUILD_PACKAGES}" ]]; then
    configure_args+=(--cmake_add_define TE_CONAN_BUILD_PACKAGES "${CONAN_BUILD_PACKAGES}")
fi

./scripts/configure.py "\${configure_args[@]}"
cmake --build "${BUILD_DIR}" --parallel "${CONCURRENCY}" --target $(printf "%q " "${container_build_targets[@]}")
EOF
)

docker run "${docker_run_args[@]}" "${image}" /bin/bash -lc "${container_script}"

if [[ "${HOST_PACKAGE}" == "true" ]]; then
    if [[ "${LINUX_DISTRO}" != "iox" && "${LINUX_DISTRO}" != "meraki" ]]; then
        echo "Skipping host Docker package step for linux_distro=${LINUX_DISTRO}."
        exit 0
    fi

    version_file="${REPO_ROOT}/${BUILD_DIR}/release/linux.version"
    installer_dir="${REPO_ROOT}/${BUILD_DIR}/installer/linux"
    resource_dir="${installer_dir}/${LINUX_DISTRO}"

    if [[ ! -f "${version_file}" ]]; then
        echo "Cannot package on host: missing ${version_file}" >&2
        exit 1
    fi
    if [[ ! -d "${resource_dir}" ]]; then
        echo "Cannot package on host: missing ${resource_dir}" >&2
        exit 1
    fi

    build_version="$(<"${version_file}")"
    if command -v python3 >/dev/null 2>&1; then
        host_python=python3
    else
        host_python=python
    fi

    echo "Packaging ${LINUX_DISTRO} Docker image on host with ${host_python}..."
    (
        cd "${REPO_ROOT}"
        "${host_python}" scripts/docker/package.py \
            --build_mode "${BUILD_MODE}" \
            --build_product "${BUILD_PRODUCT}" \
            --build_version "${build_version}" \
            --installer_dir "${installer_dir}" \
            --resource_dir "${resource_dir}" \
            --linux_distro "${LINUX_DISTRO}" \
            --build_arch "${BUILD_ARCH}"
    )
fi
