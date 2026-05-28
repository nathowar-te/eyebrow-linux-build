#!/bin/bash

# Build an Ubuntu 22.04 Linux build container, then either open an interactive
# shell or run a configure + compile flow inside it. For IOx/Meraki builds,
# the CPack package target runs in the container. IOx Docker packaging is split:
# the Docker build/save runs on the macOS host so Docker Desktop credentials are
# available, then ioxclient runs in the Linux container because it requires Linux.
# Meraki Docker packaging runs on the macOS host.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./start.sh [options]

Without --profile, opens an interactive shell in the build container.

Configure, compile, and package:
  ./start.sh \
    --profile linux-alpine322-arm64-clang21-debug \
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
      For IOx/Meraki Docker packaging, package is built automatically as well.

  --run-tests
      Build the tests target and run unit tests with scripts/test.py inside the container.

  --test-timeout SECONDS
      Per-test timeout passed to scripts/test.py. Defaults to 600.

  --test-build-config CONFIG
      Build config passed to scripts/test.py. Defaults from --profile suffix,
      falling back to Release.

  --coverage
      Pass --coverage to configure.py and scripts/test.py.

  --build-arch ARCH
      Docker package architecture, arm64 or amd64. Defaults from --profile.

  --conan-build-packages VALUE
      Passes -DTE_CONAN_BUILD_PACKAGES=<VALUE>, for example "missing".

  --skip-host-package
      Do not run scripts/container/package.py after the container build.
      IOx packaging normally runs in the container; Meraki packaging runs on the host.

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
RUN_TESTS="false"
TEST_TIMEOUT="600"
TEST_BUILD_CONFIG=""
COVERAGE="false"

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
        --run-tests)
            RUN_TESTS="true"
            shift
            ;;
        --test-timeout|--test_timeout)
            TEST_TIMEOUT="${2:?Missing value for $1}"
            shift 2
            ;;
        --test-build-config|--test_build_config)
            TEST_BUILD_CONFIG="${2:?Missing value for $1}"
            shift 2
            ;;
        --coverage)
            COVERAGE="true"
            shift
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

if [[ -z "${TEST_BUILD_CONFIG}" ]]; then
    case "${TARGET_CONAN_PROFILE}" in
        *-debug)
            TEST_BUILD_CONFIG="Debug"
            ;;
        *-release)
            TEST_BUILD_CONFIG="Release"
            ;;
        *)
            TEST_BUILD_CONFIG="Release"
            ;;
    esac
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

DOCKER_PACKAGE="false"
PACKAGE_IN_CONTAINER="false"
PACKAGE_ON_HOST="false"
if [[ "${HOST_PACKAGE}" == "true" ]]; then
    case "${LINUX_DISTRO}" in
        iox)
            DOCKER_PACKAGE="true"
            PACKAGE_IN_CONTAINER="true"
            ;;
        meraki)
            DOCKER_PACKAGE="true"
            PACKAGE_ON_HOST="true"
            ;;
    esac
fi

if [[ "${DOCKER_PACKAGE}" == "true" && "${BUILD_PRODUCT}" != "ENTERPRISE" ]]; then
    echo "Docker packaging only supports BUILD_PRODUCT=ENTERPRISE, got: ${BUILD_PRODUCT}" >&2
    exit 2
fi

container_build_targets=("${BUILD_TARGETS[@]}")
if [[ "${RUN_TESTS}" == "true" ]]; then
    has_tests_target="false"
    for target in "${container_build_targets[@]}"; do
        if [[ "${target}" == "tests" ]]; then
            has_tests_target="true"
            break
        fi
    done
    if [[ "${has_tests_target}" == "false" ]]; then
        container_build_targets+=(tests)
    fi
fi

if [[ "${DOCKER_PACKAGE}" == "true" ]]; then
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

base_docker_run_args=(
    --rm
    --privileged
    --network=host
    -v "${REPO_ROOT}:/build"
    -v "${HOME}/.conan:/root/.conan"
    -v "${HOME}/.ssh:/root/.ssh"
    -v /run/host-services/ssh-auth.sock:/run/host-services/ssh-auth.sock
    -e SSH_AUTH_SOCK=/run/host-services/ssh-auth.sock
    -v "${LOGDIR}:/var/log"
    -w /build
    --cap-add NET_ADMIN
)

if [[ -f "${HOME}/.gitconfig" ]]; then
    base_docker_run_args+=(
        -v "${HOME}/.gitconfig:/root/.gitconfig:ro"
    )
fi

find_docker_socket() {
    DOCKER_SOCKET="${DOCKER_SOCKET:-}"
    if [[ -z "${DOCKER_SOCKET}" ]]; then
        for docker_socket_candidate in /var/run/docker.sock "${HOME}/.docker/run/docker.sock"; do
            if [[ -S "${docker_socket_candidate}" ]]; then
                DOCKER_SOCKET="${docker_socket_candidate}"
                break
            fi
        done
    fi

    if [[ -z "${DOCKER_SOCKET}" || ! -S "${DOCKER_SOCKET}" ]]; then
        echo "Docker socket not found. Set DOCKER_SOCKET=/path/to/docker.sock." >&2
        exit 1
    fi
}

if [[ "${RUN_MODE}" == "shell" ]]; then
    docker run -it "${base_docker_run_args[@]}" "${image}"
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

if [[ "${COVERAGE}" == "true" ]]; then
    configure_args+=(--coverage)
fi

./scripts/configure.py "\${configure_args[@]}"
cmake --build "${BUILD_DIR}" --parallel "${CONCURRENCY}" --target $(printf "%q " "${container_build_targets[@]}")

if [[ "${RUN_TESTS}" == "true" ]]; then
    test_args=(
        --build_dir "${BUILD_DIR}"
        --build_product "${BUILD_PRODUCT}"
        --build_config "${TEST_BUILD_CONFIG}"
        --concurrency "${CONCURRENCY}"
        --timeout "${TEST_TIMEOUT}"
    )

    if [[ "${COVERAGE}" == "true" ]]; then
        test_args+=(--coverage)
    fi

    ./scripts/test.py "\${test_args[@]}"
fi

EOF
)

docker run "${base_docker_run_args[@]}" "${image}" /bin/bash -lc "${container_script}"

if [[ "${PACKAGE_IN_CONTAINER}" == "true" ]]; then
    version_file="${REPO_ROOT}/${BUILD_DIR}/release/linux.version"
    installer_dir="${REPO_ROOT}/${BUILD_DIR}/installer/linux"
    resource_dir="${installer_dir}/${LINUX_DISTRO}"

    if [[ ! -f "${version_file}" ]]; then
        echo "Cannot package IOx: missing ${version_file}" >&2
        exit 1
    fi
    if [[ ! -d "${resource_dir}" ]]; then
        echo "Cannot package IOx: missing ${resource_dir}" >&2
        exit 1
    fi

    build_version="$(<"${version_file}")"
    case "${BUILD_ARCH}" in
        arm64)
            package_arch="arm64"
            ;;
        amd64)
            package_arch="x64"
            ;;
    esac

    installer_base="te-endpoint-agent"
    case "${BUILD_MODE}" in
        DEV)
            installer_base="${installer_base}-dev"
            ;;
        STG)
            installer_base="${installer_base}-stg"
            ;;
        PROD)
            ;;
        *)
            echo "Unsupported build mode for IOx packaging: ${BUILD_MODE}" >&2
            exit 2
            ;;
    esac

    installer_name="${installer_base}-${build_version}-${LINUX_DISTRO}-${package_arch}"
    package_name="Endpoint-Agent-${build_version}-${LINUX_DISTRO}-${package_arch}"
    docker_image_name="$(printf '%s' "${package_name}" | tr '[:upper:]' '[:lower:]')"
    installer_archive="${package_name}.tar.gz"
    installer_path_src="${installer_dir}/${installer_name}.tar.gz"
    installer_path_dst="${resource_dir}/${installer_archive}"

    if [[ ! -f "${installer_path_src}" ]]; then
        echo "Cannot package IOx: missing ${installer_path_src}" >&2
        exit 1
    fi

    echo "Building IOx Docker image on host with Docker Desktop credentials..."
    cp "${installer_path_src}" "${installer_path_dst}"
    docker_build_result=0
    (
        cd "${resource_dir}"
        docker buildx build \
            --platform "linux/${BUILD_ARCH}" \
            --build-arg "PKG_FILE=${installer_archive}" \
            --load \
            --tag "${docker_image_name}" \
            .
    ) || docker_build_result=$?
    rm -f "${installer_path_dst}"
    if [[ "${docker_build_result}" -ne 0 ]]; then
        exit "${docker_build_result}"
    fi

    docker save \
        --output "${resource_dir}/${package_name}-docker.tar" \
        "${docker_image_name}"

    find_docker_socket

    iox_container_script=$(cat <<EOF
set -euo pipefail

export DOCKER_HOST=unix:///var/run/docker.sock

if [[ ! -f /root/.ioxclientcfg.yaml ]]; then
    cat >/root/.ioxclientcfg.yaml <<'IOXCLIENTCFG'
global:
  version: "1.0"
  active: default
  debug: false
  fogportalprofile:
    fogpip: ""
    fogpport: ""
    fogpapiprefix: ""
    fogpurlscheme: ""
  dockerconfig:
    server_uri: unix:///var/run/docker.sock
    api_version: "1.22"
author:
  name: |2+

  link: ""
profiles: {default: {host_ip: 127.0.0.1, host_port: 8443, auth_keys: cm9vdDo=, auth_token: "",
    local_repo: /software/downloads, api_prefix: /iox/api/v2/hosting/, url_scheme: https,
    ssh_port: 2222, rsa_key: "", certificate: "", cpu_architecture: "", middleware: {
      mw_ip: "", mw_port: "", mw_baseuri: "", mw_urlscheme: "", mw_access_token: ""},
    conn_timeout: 1000, client_auth: "no", client_cert: "", client_key: ""}}
IOXCLIENTCFG
fi

installer_dir="/build/${BUILD_DIR}/installer/linux"
resource_dir="\${installer_dir}/${LINUX_DISTRO}"
package_name="${package_name}"
docker_image_name="${docker_image_name}"
iox_package_name="\${package_name}.package"
work_dir="\$(mktemp -d /tmp/iox-package.XXXXXX)"
iox_package_path="\${work_dir}/\${iox_package_name}.tar"
resource_iox_package_path="\${resource_dir}/\${iox_package_name}.tar"
activation_path="\${resource_dir}/activation.json"
work_activation_path="\${work_dir}/activation.json"
bundle_path="\${work_dir}/\${package_name}.bundle.tar"
resource_bundle_path="\${resource_dir}/\${package_name}.bundle.tar"
package_path="\${installer_dir}/\${package_name}.tar"
work_package_path="\${work_dir}/\${package_name}.tar"

trap 'rm -rf "\${work_dir}"' EXIT

if [[ ! -f "\${resource_dir}/package.yaml" ]]; then
    echo "Cannot package IOx: missing \${resource_dir}/package.yaml" >&2
    exit 1
fi
if [[ ! -f "\${activation_path}" ]]; then
    echo "Cannot create IOx bundle: missing \${activation_path}" >&2
    exit 1
fi

cp "\${resource_dir}/package.yaml" "\${work_dir}/"
cp "\${activation_path}" "\${work_activation_path}"

echo "Packaging IOx image inside Linux container with ioxclient..."
ioxclient docker package \
    --package-type ext2 \
    --name "\${iox_package_name}" \
    "\${docker_image_name}" \
    "\${work_dir}"

if [[ ! -f "\${iox_package_path}" ]]; then
    echo "ioxclient did not create expected package: \${iox_package_path}" >&2
    exit 1
fi

rm -f "\${resource_iox_package_path}" "\${resource_bundle_path}" "\${package_path}"

tmp_bundle_dir="\${work_dir}/bundle"
mkdir -p "\${tmp_bundle_dir}"
cp "\${iox_package_path}" "\${tmp_bundle_dir}/"
cp "\${work_activation_path}" "\${tmp_bundle_dir}/\${package_name}.activation.json"
tar -cf "\${bundle_path}" -C "\${tmp_bundle_dir}" "\${iox_package_name}.tar" "\${package_name}.activation.json"
tar -cf "\${work_package_path}" -C "\${work_dir}" "\${package_name}.bundle.tar"

cp "\${iox_package_path}" "\${resource_iox_package_path}"
cp "\${bundle_path}" "\${resource_bundle_path}"
cp "\${work_package_path}" "\${package_path}"

echo "Successfully created IOx package: \${package_path}"
EOF
)

    docker run \
        "${base_docker_run_args[@]}" \
        -v "${DOCKER_SOCKET}:/var/run/docker.sock" \
        "${image}" \
        /bin/bash -lc "${iox_container_script}"
fi

if [[ "${PACKAGE_ON_HOST}" == "true" ]]; then
    if [[ "${LINUX_DISTRO}" != "meraki" ]]; then
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
        "${host_python}" scripts/container/package.py \
            --build_mode "${BUILD_MODE}" \
            --build_product "${BUILD_PRODUCT}" \
            --build_version "${build_version}" \
            --installer_dir "${installer_dir}" \
            --resource_dir "${resource_dir}" \
            --linux_distro "${LINUX_DISTRO}" \
            --build_arch "${BUILD_ARCH}"
    )
fi
