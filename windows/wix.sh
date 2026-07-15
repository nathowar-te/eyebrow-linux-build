#!/bin/bash

set -euo pipefail

export WINEDEBUG="${WINEDEBUG:--all}"
export WINEPREFIX="${WINEPREFIX:-/opt/wine-prefix}"

wix_dll='Z:\opt\wix\tools\net6.0\any\wix.dll'
util_extension='Z:\opt\wix-extensions\WixToolset.Util.wixext.dll'
ui_extension='Z:\opt\wix-extensions\WixToolset.UI.wixext.dll'
rootfs='/opt/wix-rootfs'
wine64='/usr/lib/wine/wine64'
binfmt_directory='/proc/sys/fs/binfmt_misc'
binfmt_handler_name='eyebrow-qemu-x86_64'
binfmt_handler="${binfmt_directory}/${binfmt_handler_name}"
registered_binfmt=false
bind_mounts=()

cleanup()
{
    for ((i = ${#bind_mounts[@]} - 1; i >= 0; --i)); do
        umount --lazy "${bind_mounts[i]}" || true
    done

    if [[ "${registered_binfmt}" == "true" && -e "${binfmt_handler}" ]]; then
        echo -1 > "${binfmt_handler}"
    fi

    return 0
}
trap cleanup EXIT

if [[ ! -e "${binfmt_directory}/register" ]]; then
    mount -t binfmt_misc binfmt_misc "${binfmt_directory}"
fi

if [[ -e "${binfmt_handler}" ]]; then
    echo -1 > "${binfmt_handler}"
fi
sed "s/^:qemu-x86_64:/:${binfmt_handler_name}:/" \
    /usr/lib/binfmt.d/qemu-x86_64.conf > "${binfmt_directory}/register"
registered_binfmt=true

for bind_path in /dev /proc /build /root/.conan; do
    if [[ -e "${bind_path}" ]]; then
        guest_path="${rootfs}${bind_path}"
        mkdir -p "${guest_path}"
        mount --rbind "${bind_path}" "${guest_path}"
        bind_mounts+=("${guest_path}")
    fi
done

run_wine()
{
    chroot "${rootfs}" /bin/bash -c \
        'cd "$1" && shift && exec "$@"' bash "${PWD}" "${wine64}" "$@"
}

arguments=()
if [[ "${1:-}" == "build" ]]; then
    arguments+=(build -defaultcompressionlevel mszip)
    shift
fi

previous_argument=""
for argument in "$@"; do
    if [[ "${previous_argument}" == "-ext" ]]; then
        case "${argument}" in
            WixToolset.Util.wixext)
                argument="${util_extension}"
                ;;
            WixToolset.UI.wixext)
                argument="${ui_extension}"
                ;;
        esac
    elif [[ "${argument}" == /* ]]; then
        argument="$(run_wine winepath.exe -w "${argument}")"
    fi

    arguments+=("${argument}")
    previous_argument="${argument}"
done

run_wine /opt/dotnet/dotnet.exe "${wix_dll}" "${arguments[@]}"
