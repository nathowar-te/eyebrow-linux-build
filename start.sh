#!/bin/bash

# Use this script to start a basic Linux shell environment using ubuntu2204 with build dependencies installed for building and running the agent.

set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "${DIR}/../" && pwd )"

echo "Repository root: ${REPO_ROOT}"

# Create a directory for the agent logs
LOGDIR="${DIR}/logs"
mkdir -p ${LOGDIR}

# Build the image
image=$(docker build --build-context eyebrow=${REPO_ROOT} -q "${DIR}")

echo "Using image: ${image}"

docker run -it --rm \
    --privileged \
    -v "${REPO_ROOT}":/build \
    -v "${HOME}/.conan:/root/.conan" \
    -v "${HOME}/.ssh:/root/.ssh" \
    -v "${LOGDIR}:/var/log" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -w /build \
    --cap-add NET_ADMIN \
    ${image}
