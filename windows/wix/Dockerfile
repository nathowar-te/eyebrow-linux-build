ARG WIX_ROOTFS_PLATFORM=linux/amd64

FROM --platform=$WIX_ROOTFS_PLATFORM ubuntu:24.04 AS wix-rootfs

ENV DEBIAN_FRONTEND=noninteractive

ARG WIX_VERSION=5.0.2

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      p7zip-full \
      python3 \
      unzip \
      wine64 && \
    rm -rf /var/lib/apt/lists/*

COPY windows/install-msvc-redist.sh /usr/local/bin/install-msvc-redist

RUN chmod +x /usr/local/bin/install-msvc-redist && \
    install-msvc-redist

RUN mkdir -p /opt/dotnet /opt/wix /opt/wix-extensions && \
    curl -fsSL https://aka.ms/dotnet/6.0/dotnet-runtime-win-x64.zip \
      -o /tmp/dotnet.zip && \
    unzip -q /tmp/dotnet.zip -d /opt/dotnet && \
    curl -fsSL \
      "https://api.nuget.org/v3-flatcontainer/wix/${WIX_VERSION}/wix.${WIX_VERSION}.nupkg" \
      -o /tmp/wix.zip && \
    unzip -q /tmp/wix.zip -d /opt/wix && \
    curl -fsSL \
      "https://api.nuget.org/v3-flatcontainer/wixtoolset.util.wixext/${WIX_VERSION}/wixtoolset.util.wixext.${WIX_VERSION}.nupkg" \
      -o /tmp/wix-util.zip && \
    unzip -p /tmp/wix-util.zip wixext5/WixToolset.Util.wixext.dll \
      > /opt/wix-extensions/WixToolset.Util.wixext.dll && \
    curl -fsSL \
      "https://api.nuget.org/v3-flatcontainer/wixtoolset.ui.wixext/${WIX_VERSION}/wixtoolset.ui.wixext.${WIX_VERSION}.nupkg" \
      -o /tmp/wix-ui.zip && \
    unzip -p /tmp/wix-ui.zip wixext5/WixToolset.UI.wixext.dll \
      > /opt/wix-extensions/WixToolset.UI.wixext.dll && \
    rm /tmp/dotnet.zip /tmp/wix.zip /tmp/wix-util.zip /tmp/wix-ui.zip

FROM --platform=$BUILDPLATFORM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV WINEDEBUG=-all
ENV WINEPREFIX=/opt/wine-prefix

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      cmake \
      ninja-build \
      python3 \
      python3-venv \
      qemu-user-static && \
    rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /venv && \
    /venv/bin/pip install --no-cache-dir click==8.2.1 jinja2==3.1.6

COPY --from=wix-rootfs / /opt/wix-rootfs/
COPY --from=wix-rootfs /opt/msvc-redist /opt/msvc-redist
COPY windows/build-msi.sh /usr/local/bin/build-msi
COPY windows/wix.sh /usr/local/bin/wix

RUN chmod +x /usr/local/bin/build-msi /usr/local/bin/wix
