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

  --windows-msvc
      Configure/build a Windows MSVC-ABI target inside the Linux container using
      clang-cl/lld-link and xwin. Experimental; compile validation only, not
      installer/signing.

  --windows-msi
      Build the x86 MSI on a Windows VM and copy it to build/windows-vm-msi.

  --windows-vm-host HOST
      Windows VM hostname or address. Required with --windows-msi unless
      WINDOWS_VM_HOST is set.

  --windows-vm-user USER
      Windows SSH user. Defaults to Administrator.

  --windows-vm-jump HOST
      SSH ProxyJump host used to reach the Windows VM.

  --windows-vm-password-env NAME
      Environment variable containing the Windows SSH password. Defaults to
      WINDOWS_VM_PASSWORD. Key-based SSH is used when the variable is empty.

  --windows-vm-work-dir PATH
      Remote Windows work directory. Defaults to C:\Dev\eyebrow-msi-build.

  --windows-vm-bootstrap-tools
      Install missing Visual Studio Build Tools, Python, .NET, Git, and Node.js
      on the VM with winget before building.

  --windows-vm-artifactory-tunnel
      Forward the internal Artifactory HTTPS endpoint through SSH for CML VMs
      without corporate DNS or direct Artifactory routing.

  --windows-vm-copy-conan-credentials
      Temporarily copy the local Conan 1 credential database to the VM for the
      build. The VM database is restored and the uploaded copy is deleted.

  --windows-msi-output-dir DIR
      Local output directory. Defaults to build/windows-vm-msi.

  --build-dir DIR
      Build directory inside the repo mount. Defaults to build/<linux-distro>,
      or build/windows-msvc with --windows-msvc.

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
WINDOWS_MSVC="false"
WINDOWS_MSI="false"
WINDOWS_VM_HOST="${WINDOWS_VM_HOST:-}"
WINDOWS_VM_USER="Administrator"
WINDOWS_VM_JUMP=""
WINDOWS_VM_PASSWORD_ENV="WINDOWS_VM_PASSWORD"
WINDOWS_VM_WORK_DIR='C:\Dev\eyebrow-msi-build'
WINDOWS_VM_BOOTSTRAP_TOOLS="false"
WINDOWS_VM_ARTIFACTORY_TUNNEL="false"
WINDOWS_VM_COPY_CONAN_CREDENTIALS="false"
WINDOWS_MSI_OUTPUT_DIR=""
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
        --windows-msvc|--windows_msvc)
            WINDOWS_MSVC="true"
            shift
            ;;
        --windows-msi|--windows_msi)
            WINDOWS_MSVC="true"
            WINDOWS_MSI="true"
            shift
            ;;
        --windows-vm-host|--windows_vm_host)
            WINDOWS_VM_HOST="${2:?Missing value for $1}"
            shift 2
            ;;
        --windows-vm-user|--windows_vm_user)
            WINDOWS_VM_USER="${2:?Missing value for $1}"
            shift 2
            ;;
        --windows-vm-jump|--windows_vm_jump)
            WINDOWS_VM_JUMP="${2:?Missing value for $1}"
            shift 2
            ;;
        --windows-vm-password-env|--windows_vm_password_env)
            WINDOWS_VM_PASSWORD_ENV="${2:?Missing value for $1}"
            shift 2
            ;;
        --windows-vm-work-dir|--windows_vm_work_dir)
            WINDOWS_VM_WORK_DIR="${2:?Missing value for $1}"
            shift 2
            ;;
        --windows-vm-bootstrap-tools|--windows_vm_bootstrap_tools)
            WINDOWS_VM_BOOTSTRAP_TOOLS="true"
            shift
            ;;
        --windows-vm-artifactory-tunnel|--windows_vm_artifactory_tunnel)
            WINDOWS_VM_ARTIFACTORY_TUNNEL="true"
            shift
            ;;
        --windows-vm-copy-conan-credentials|--windows_vm_copy_conan_credentials)
            WINDOWS_VM_COPY_CONAN_CREDENTIALS="true"
            shift
            ;;
        --windows-msi-output-dir|--windows_msi_output_dir)
            WINDOWS_MSI_OUTPUT_DIR="${2:?Missing value for $1}"
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

if [[ "${WINDOWS_MSVC}" == "true" ]]; then
    RUN_MODE="build"
    if [[ -z "${TARGET_CONAN_PROFILE}" || -z "${BUILD_CONAN_PROFILE}" ]]; then
        echo "Windows MSVC mode requires --profile and --build-conan-profile." >&2
        usage >&2
        exit 2
    fi
    if [[ -n "${LINUX_DISTRO}" ]]; then
        echo "Windows MSVC mode does not use --linux-distro." >&2
        usage >&2
        exit 2
    fi
    if [[ "${WINDOWS_MSI}" == "true" ]]; then
        if [[ -z "${WINDOWS_VM_HOST}" ]]; then
            echo "--windows-msi requires --windows-vm-host or WINDOWS_VM_HOST." >&2
            exit 2
        fi

        windows_msi_args=(
            --repo-root "${REPO_ROOT}"
            --vm-host "${WINDOWS_VM_HOST}"
            --vm-user "${WINDOWS_VM_USER}"
            --vm-password-env "${WINDOWS_VM_PASSWORD_ENV}"
            --vm-work-dir "${WINDOWS_VM_WORK_DIR}"
            --target-conan-profile "${TARGET_CONAN_PROFILE}"
            --build-conan-profile "${BUILD_CONAN_PROFILE}"
            --build-mode "${BUILD_MODE}"
            --build-product "${BUILD_PRODUCT}"
            --concurrency "${CONCURRENCY}"
        )
        if [[ -n "${WINDOWS_VM_JUMP}" ]]; then
            windows_msi_args+=(--vm-jump "${WINDOWS_VM_JUMP}")
        fi
        if [[ -n "${WINDOWS_MSI_OUTPUT_DIR}" ]]; then
            windows_msi_args+=(--output-dir "${WINDOWS_MSI_OUTPUT_DIR}")
        fi
        if [[ "${WINDOWS_VM_BOOTSTRAP_TOOLS}" == "true" ]]; then
            windows_msi_args+=(--bootstrap-tools)
        fi
        if [[ "${WINDOWS_VM_ARTIFACTORY_TUNNEL}" == "true" ]]; then
            windows_msi_args+=(--artifactory-tunnel)
        fi
        if [[ "${WINDOWS_VM_COPY_CONAN_CREDENTIALS}" == "true" ]]; then
            windows_msi_args+=(--copy-conan-credentials)
        fi

        exec "${DIR}/windows/build-msi-vm.sh" "${windows_msi_args[@]}"
    fi
elif [[ -z "${TARGET_CONAN_PROFILE}" && -z "${BUILD_CONAN_PROFILE}" && -z "${LINUX_DISTRO}" ]]; then
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
    if [[ "${WINDOWS_MSVC}" == "true" ]]; then
        BUILD_DIR="build/windows-msvc"
    else
        BUILD_DIR="build/${LINUX_DISTRO:-linux}"
    fi
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

if [[ "${WINDOWS_MSVC}" != "true" && "${BUILD_ARCH}" != "arm64" && "${BUILD_ARCH}" != "amd64" ]]; then
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

container_repo_root="${REPO_ROOT}"
if [[ "${WINDOWS_MSVC}" == "true" ]]; then
    windows_source_archive="${requirements_context}/eyebrow-source.tar.gz"
    windows_source_directory="${requirements_context}/eyebrow-source"
    mkdir -p "${windows_source_directory}" "${REPO_ROOT}/${BUILD_DIR}"

    echo "Staging an isolated Windows build source tree..."
    COPYFILE_DISABLE=1 tar -czf "${windows_source_archive}" \
        --exclude './.git' \
        --exclude './.cache' \
        --exclude './.mypy_cache' \
        --exclude './.nox' \
        --exclude './.ruff_cache' \
        --exclude './.venv' \
        --exclude './build' \
        --exclude './build-*' \
        --exclude './e2e' \
        --exclude './eyebrow-linux-build' \
        -C "${REPO_ROOT}" .
    tar -xzf "${windows_source_archive}" -C "${windows_source_directory}"
    patch -d "${windows_source_directory}" -p1 \
        < "${DIR}/windows/patches/eyebrow-windows-build.patch"
    container_repo_root="${windows_source_directory}"
fi

# Build the image. Use an iidfile instead of quiet stdout capture so Docker's
# progress output remains visible while still giving us the image ID afterward.
iidfile="$(mktemp "${TMPDIR:-/tmp}/eyebrow-linux-build-image.XXXXXX")"
trap 'rm -f "${iidfile}"; rm -rf "${requirements_context}"' EXIT
docker build \
    --network=host \
    --allow network.host \
    --build-arg "INSTALL_WINDOWS_MSVC_TOOLCHAIN=${WINDOWS_MSVC}" \
    --build-context python_requirements="${requirements_context}" \
    --iidfile "${iidfile}" \
    "${DIR}"
image="$(<"${iidfile}")"

echo "Using image: ${image}"

base_docker_run_args=(
    --rm
    --privileged
    --network=host
    -v "${container_repo_root}:/build"
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

if [[ "${WINDOWS_MSVC}" == "true" ]]; then
    xwin_toolchain_dir="${REPO_ROOT}/.cache/xwin"
    xwin_cache_dir="${HOME}/.cache/xwin"
    mkdir -p "${xwin_toolchain_dir}" "${xwin_cache_dir}"
    base_docker_run_args+=(
        -v "${REPO_ROOT}/${BUILD_DIR}:/build/${BUILD_DIR}"
        -v "${xwin_toolchain_dir}:/opt/xwin"
        -v "${xwin_cache_dir}:/root/.cache/xwin"
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

WINDOWS_ARCH=""
VSCMD_ARCH=""
CLANG_TARGET=""
if [[ "${WINDOWS_MSVC}" == "true" ]]; then
    case "${TARGET_CONAN_PROFILE}" in
        windows-x86-*)
            WINDOWS_ARCH="x86"
            VSCMD_ARCH="x86"
            CLANG_TARGET="i686-pc-windows-msvc"
            ;;
        windows-x64-*|windows-x86_64-*)
            WINDOWS_ARCH="x86_64"
            VSCMD_ARCH="x64"
            CLANG_TARGET="x86_64-pc-windows-msvc"
            ;;
        *)
            echo "Unsupported Windows MSVC target profile: ${TARGET_CONAN_PROFILE}" >&2
            exit 2
            ;;
    esac
fi

container_build_targets_literal="$(printf "%q " "${container_build_targets[@]}")"

container_script=$(cat <<EOF
set -euo pipefail

source /venv/bin/activate

cmake_build_targets=(${container_build_targets_literal})

configure_args=(
    --build_dir "${BUILD_DIR}"
    --build_mode "${BUILD_MODE}"
    --build_product "${BUILD_PRODUCT}"
    --profile "${TARGET_CONAN_PROFILE}"
    --build_conan_profile "${BUILD_CONAN_PROFILE}"
)

if [[ "${WINDOWS_MSVC}" == "true" ]]; then
    if [[ ! -f /opt/xwin/sdk/lib/um/${WINDOWS_ARCH}/kernel32.lib ||
          ! -f /opt/xwin/crt/lib/${WINDOWS_ARCH}/msvcrt.lib ||
          ! -f /opt/xwin/crt/lib/${WINDOWS_ARCH}/msvcrtd.lib ||
          ! -f /opt/xwin/crt/include/atlbase.h ||
          ! -f /opt/xwin/crt/include/atlsecurity.h ]]; then
        rm -rf /opt/xwin/crt /opt/xwin/sdk
        xwin --accept-license --cache-dir /root/.cache/xwin --arch "${WINDOWS_ARCH}" --include-debug-runtime --include-atl splat --include-debug-libs --copy --output /opt/xwin
    fi

    windows_linker_flags="/libpath:/opt/xwin/crt/lib/${WINDOWS_ARCH} /libpath:/opt/xwin/sdk/lib/ucrt/${WINDOWS_ARCH} /libpath:/opt/xwin/sdk/lib/um/${WINDOWS_ARCH}"

    export PATH="/opt/te/llvm-21/bin:\${PATH}"
    export VSCMD_ARG_TGT_ARCH="${VSCMD_ARCH}"
    export CC=/opt/te/llvm-21/bin/clang-cl
    export CXX=/opt/te/llvm-21/bin/clang-cl
    xwin_include_flags="-imsvc/opt/xwin/crt/include -imsvc/opt/xwin/sdk/include/ucrt -imsvc/opt/xwin/sdk/include/um -imsvc/opt/xwin/sdk/include/shared -imsvc/opt/xwin/sdk/include/winrt -imsvc/opt/xwin/sdk/include/cppwinrt"
    xwin_rc_include_flags="-I/opt/xwin/crt/include -I/opt/xwin/sdk/include/ucrt -I/opt/xwin/sdk/include/um -I/opt/xwin/sdk/include/shared"
    clang_cl_warning_flags="-Wno-unused-command-line-argument -Wno-c++98-compat -Wno-c++98-compat-pedantic -Wno-padded -Wno-unique-object-duplication -Wno-exit-time-destructors -Wno-nrvo -Wno-sign-conversion -Wno-missing-prototypes -Wno-covered-switch-default -Wno-switch-default -Wno-switch-enum -Wno-documentation -Wno-documentation-unknown-command -Wno-gnu-zero-variadic-macro-arguments -Wno-unsafe-buffer-usage -Wno-thread-safety-analysis -Wno-thread-safety-attributes -Wno-unqualified-std-cast-call -Wno-global-constructors -Wno-unused-template -Wno-reserved-identifier -Wno-invalid-offsetof -Wno-ctad-maybe-unsupported -Wno-implicit-int-conversion -Wno-shadow -Wno-shadow-uncaptured-local -Wno-deprecated-copy-with-user-provided-dtor -Wno-missing-include-dirs -Wno-unreachable-code-return -Wno-implicit-int-float-conversion -Wno-zero-as-null-pointer-constant -Wno-unreachable-code-break -Wno-missing-field-initializers -Wno-inconsistent-missing-destructor-override -Wno-suggest-destructor-override -Wno-suggest-override -Wno-missing-noreturn -Wno-cast-function-type-strict -Wno-tautological-type-limit-compare -Wno-extra-semi-stmt -Wno-old-style-cast -Wno-conditional-uninitialized -Wno-nonportable-system-include-path -Wno-disabled-macro-expansion"
    export CFLAGS="--target=${CLANG_TARGET} \${clang_cl_warning_flags} \${xwin_include_flags}"
    export CXXFLAGS="--target=${CLANG_TARGET} \${clang_cl_warning_flags} \${xwin_include_flags}"
    export LDFLAGS="\${windows_linker_flags}"
    export INCLUDE="/opt/xwin/crt/include:/opt/xwin/sdk/include/ucrt:/opt/xwin/sdk/include/um:/opt/xwin/sdk/include/shared:/opt/xwin/sdk/include/winrt:/opt/xwin/sdk/include/cppwinrt"
    export LIB="/opt/xwin/crt/lib/${WINDOWS_ARCH}:/opt/xwin/sdk/lib/ucrt/${WINDOWS_ARCH}:/opt/xwin/sdk/lib/um/${WINDOWS_ARCH}"
    export LIBPATH="\${LIB}"
    export CONAN_CMAKE_GENERATOR=Ninja

    configure_args+=(
        --generator "Ninja Multi-Config"
        --cmake_add_define TE_COMPILER_TARGET "${CLANG_TARGET}"
        --cmake_add_define CMAKE_SYSTEM_NAME Windows
        --cmake_add_define CMAKE_SYSTEM_PROCESSOR "${WINDOWS_ARCH}"
        --cmake_add_define CMAKE_C_COMPILER_TARGET "${CLANG_TARGET}"
        --cmake_add_define CMAKE_CXX_COMPILER_TARGET "${CLANG_TARGET}"
        --cmake_add_define CMAKE_C_COMPILER /opt/te/llvm-21/bin/clang-cl
        --cmake_add_define CMAKE_CXX_COMPILER /opt/te/llvm-21/bin/clang-cl
        --cmake_add_define CMAKE_RC_COMPILER /opt/te/llvm-21/bin/llvm-rc
        --cmake_add_define CMAKE_RC_FLAGS "\${xwin_rc_include_flags}"
        --cmake_add_define CMAKE_MT /usr/bin/llvm-mt
        --cmake_add_define CMAKE_LINKER /opt/te/llvm-21/bin/lld-link
        --cmake_add_define CMAKE_AR /opt/te/llvm-21/bin/llvm-lib
        --cmake_add_define CMAKE_TRY_COMPILE_CONFIGURATION Release
        --cmake_add_define CMAKE_COMPILE_WARNING_AS_ERROR FALSE
        --cmake_add_define CONAN_DISABLE_CHECK_COMPILER 1
        --cmake_add_define USE_PCH OFF
        --cmake_add_define CMAKE_EXE_LINKER_FLAGS "\${windows_linker_flags}"
        --cmake_add_define CMAKE_SHARED_LINKER_FLAGS "\${windows_linker_flags}"
        --cmake_add_define CMAKE_MODULE_LINKER_FLAGS "\${windows_linker_flags}"
    )
    configure_args+=(
        --cmake_add_define TE_SKIP_INSTALLER ON
    )
else
    configure_args+=(--linux_distro "${LINUX_DISTRO}")
fi

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

build_cmake_targets() {
    if [[ "\$#" -eq 0 ]]; then
        return
    fi
    cmake_build_args=(
        --build "${BUILD_DIR}"
        --parallel "${CONCURRENCY}"
    )
    if [[ "${WINDOWS_MSVC}" == "true" ]]; then
        cmake_build_args+=(--config "${TEST_BUILD_CONFIG}")
    fi
    cmake_build_args+=(--target "\$@")
    cmake "\${cmake_build_args[@]}"
}

build_cmake_targets "\${cmake_build_targets[@]}"

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
