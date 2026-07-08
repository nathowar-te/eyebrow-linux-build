FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      software-properties-common \
      wget \
      curl \
      ca-certificates \
      gnupg2

RUN apt-get update && \
    apt-get install -y \
      ninja-build \
      git \
      g++ \
      clang \
      llvm \
      lld

# Install Kitware’s APT repo to get CMake 3.26+
RUN apt-get install -y \
      lsb-release && \
    wget -qO - https://apt.kitware.com/keys/kitware-archive-latest.asc \
      | apt-key add - && \
    apt-add-repository \
      "deb https://apt.kitware.com/ubuntu/ $(lsb_release -cs) main" && \
    apt install -y cmake

# Install python3.12
RUN add-apt-repository ppa:deadsnakes/ppa
RUN apt install -y python3.12 python3.12-venv python3-pip

# Setup venv
RUN python3.12 -m venv venv && . venv/bin/activate && \
    pip install --no-cache-dir "conan>=1,<2"

RUN --mount=from=python_requirements,source=requirements.txt,target=/tmp/requirements.txt \
 . venv/bin/activate && pip install -r /tmp/requirements.txt

# Linux build dependencies
RUN apt install -y libmnl-dev libdbus-1-dev ccache e2fsprogs

# Optional Windows/MSVC ABI cross-build support. Visual Studio Build Tools are Windows-only,
# so Linux builds use xwin to acquire the Windows SDK/MSVC headers and libraries, then compile
# with clang-cl/lld-link.
ARG INSTALL_WINDOWS_MSVC_TOOLCHAIN=false
RUN if [ "${INSTALL_WINDOWS_MSVC_TOOLCHAIN}" = "true" ]; then \
      apt-get update && \
      apt-get install -y --no-install-recommends pkg-config libssl-dev && \
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
        sh -s -- -y --profile minimal && \
      /root/.cargo/bin/cargo install xwin --locked && \
      cp /root/.cargo/bin/xwin /usr/local/bin/xwin && \
      grep -v '.cargo/env' /root/.profile > /tmp/root-profile && \
      mv /tmp/root-profile /root/.profile && \
      rm -rf /root/.cargo /root/.rustup; \
    fi

# Install Docker CE
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list && \
    apt-get update && \
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Install ioxclient (Cisco IOx Client) v1.17.0.0
# https://developer.cisco.com/docs/iox/iox-resource-downloads/
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "amd64" ]; then \
      IOX_ARCH="amd64"; \
    elif [ "$ARCH" = "arm64" ]; then \
      IOX_ARCH="arm64"; \
    else \
      echo "Unsupported architecture: $ARCH" && exit 1; \
    fi && \
    curl -fsSL "https://pubhub.devnetcloud.com/media/iox/docs/artifacts/ioxclient/ioxclient-v1.17.0.0/ioxclient_1.17.0.0_linux_${IOX_ARCH}.tar.gz" \
      -o /tmp/ioxclient.tar.gz && \
    tar -xzf /tmp/ioxclient.tar.gz -C /tmp && \
    mv /tmp/ioxclient_1.17.0.0_linux_${IOX_ARCH}/ioxclient /usr/local/bin/ioxclient && \
    chmod +x /usr/local/bin/ioxclient && \
    rm -rf /tmp/ioxclient.tar.gz /tmp/ioxclient_1.17.0.0_linux_${IOX_ARCH}

# Install te-endpoint-llvm-toolchain
RUN curl -fsSL https://internal.repo.stg.thousandeyes.com/thousandeyes-apt-key.pub | \
      gpg --dearmor -o /etc/apt/keyrings/thousandeyes-internal-stg.gpg && \
    echo "deb [arch=amd64,arm64 signed-by=/etc/apt/keyrings/thousandeyes-internal-stg.gpg] https://internal.repo.stg.thousandeyes.com jammy main" \
      > /etc/apt/sources.list.d/thousandeyes-internal.list && \
    dpkg --add-architecture amd64 && \
    apt-get update \
      -o Dir::Etc::sourcelist="sources.list.d/thousandeyes-internal.list" \
      -o Dir::Etc::sourceparts="-" \
      -o APT::Get::List-Cleanup="0" && \
    apt-get install --no-install-recommends -y \
      te-endpoint-llvm-toolchain-21 \
      te-endpoint-musl-runtime:amd64 \
      te-endpoint-musl-runtime:arm64

CMD ["/bin/bash", "-c", "source /venv/bin/activate && exec bash"]
