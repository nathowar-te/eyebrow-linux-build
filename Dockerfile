FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      software-properties-common \
      wget \
      gnupg2

RUN apt-get install -y \
      ninja-build \
      git \
      g++

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

RUN --mount=from=eyebrow,target=/eyebrow \
 . venv/bin/activate && pip install -r /eyebrow/scripts/requirements.txt

# Linux build dependencies
RUN apt install -y libmnl-dev libdbus-1-dev

CMD ["/bin/bash", "-c", "source /venv/bin/activate && exec bash"]