#!/usr/bin/env bash
#
# Copyright (c) Microsoft Corporation. All rights reserved.
#
# Description:
# Docker wrapper script to build CVM images
#
set -euo pipefail

# Script to run the CVM image build in a Docker container

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="cvm-image-builder"
IMAGE_TAG="latest"

usage() {
    echo "Docker wrapper for build-cvm-image.sh"
    echo ""
    echo "This script builds a Docker container and runs the CVM image build process inside it."
    echo "All arguments are passed through to the build script inside the container."
    echo ""
    echo "Usage: $0 [build_script_arguments...]"
    echo ""
    echo "Examples:"
    echo "  $0 --username user --image vm.vhdx"
    echo "  $0 --username user --image vm.vhdx --ssh-key ~/.ssh/id_rsa.pub"
    echo "  $0 --username user --image vm.vhdx --ssh-key ~/.ssh/id_rsa.pub --passwordless-sudo"
    echo "  $0 --username user --image vm.vhdx --allow-ssh-password"
    echo "  $0 --username user --image vm.vhdx --allow-serial-console"
    echo "  $0 --username user --image vm.vhdx --password-hash <hash>"
    echo "  $0 --username user --image vm.vhdx --package-dir ./local-pkgs"
    echo ""
    echo "Additional Docker options:"
    echo "  --docker-rebuild    Force rebuild of the Docker image"
    echo "  --docker-help      Show this help message"
    echo ""
    echo "Build script options:"
    echo "  --insiders-fast     Enable packages.microsoft.com insiders-fast apt repo"
    echo "  --verbose-output    Print the full build log to the console instead of just the summary"
    exit 1
}

# Parse Docker-specific arguments first
REBUILD_IMAGE=false
FILTERED_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --docker-help)
            usage
            ;;
        --docker-rebuild)
            REBUILD_IMAGE=true
            shift
            ;;
        *)
            FILTERED_ARGS+=("$1")
            shift
            ;;
    esac
done

# Restore filtered arguments
set -- "${FILTERED_ARGS[@]}"

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    echo "Error: Docker is not installed or not in PATH"
    echo "Please install Docker first: https://docs.docker.com/engine/install/"
    exit 1
fi

# Check if Docker daemon is running
if ! docker info &> /dev/null; then
    echo "Error: Docker daemon is not running"
    echo "Please start Docker first"
    exit 1
fi

# Check if image exists and needs rebuilding
IMAGE_EXISTS=$(docker images -q "${IMAGE_NAME}:${IMAGE_TAG}" 2>/dev/null || true)

if [[ -z "$IMAGE_EXISTS" ]] || [[ "$REBUILD_IMAGE" == true ]]; then
    echo "Building Docker image: ${IMAGE_NAME}:${IMAGE_TAG}"
    echo "This may take a few minutes..."
    
    docker build \
        --tag "${IMAGE_NAME}:${IMAGE_TAG}" \
        --file "${SCRIPT_DIR}/Dockerfile" \
        "${SCRIPT_DIR}" || {
        echo "Error: Failed to build Docker image"
        exit 1
    }
    echo "✓ Docker image built successfully"
else
    echo "Using existing Docker image: ${IMAGE_NAME}:${IMAGE_TAG}"
    echo "Use --docker-rebuild to force rebuild"
fi

# Ensure build and out directories exist on host
mkdir -p "${SCRIPT_DIR}/build"
mkdir -p "${SCRIPT_DIR}/out"

echo ""
echo "Starting containerized build..."
echo "Build artifacts will be available in: ${SCRIPT_DIR}/build/"
echo "Output image will be available in: ${SCRIPT_DIR}/out/"
echo "Rootfs will be stored in Docker volume: cvm-build-rootfs"
echo ""

# Set up Docker arguments
DOCKER_ARGS=(
    "--rm"
    "--privileged"
    "--cap-add=SYS_ADMIN"
    "--cap-add=MKNOD"
    "--device=/dev/loop-control"
    "--volume" "/dev:/dev"
    "--volume" "${SCRIPT_DIR}/build:/workspace/build"
    "--volume" "${SCRIPT_DIR}/out:/workspace/out"
    "--volume" "${SCRIPT_DIR}/rootfs-files:/workspace/rootfs-files:ro"
)

# Only request interactive TTY allocation when running in a terminal.
# CI environments often have no TTY and `docker run -t` will fail.
if [[ -t 0 && -t 1 ]]; then
    DOCKER_ARGS+=("--interactive" "--tty")
fi

# Add rootfs mount - either volume or bind mount
# Create volume if it doesn't exist
docker volume create cvm-build-rootfs >/dev/null 2>&1 || true
DOCKER_ARGS+=("--volume" "cvm-build-rootfs:/workspace/rootfs")

# Process arguments and handle file mounts
CONTAINER_ARGS=()
ARGS=("$@")  # Convert positional parameters to array
i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
    arg="${ARGS[$i]}"
    
    case "$arg" in
        --ssh-key)
            # Next argument should be the file path
            CONTAINER_ARGS+=("$arg")
            i=$((i + 1))
            if [[ $i -lt ${#ARGS[@]} ]]; then
                CONFIG_FILE="${ARGS[$i]}"
                if [[ -f "$CONFIG_FILE" ]]; then
                    # Convert to absolute path
                    CONFIG_ABS=$(realpath "$CONFIG_FILE")
                    CONFIG_CONTAINER="/workspace/$(basename "$CONFIG_FILE")"
                    DOCKER_ARGS+=(
                        "--volume" "${CONFIG_ABS}:${CONFIG_CONTAINER}:ro"
                    )
                    # Use container path in arguments
                    CONTAINER_ARGS+=("$CONFIG_CONTAINER")
                else
                    echo "Error: Configuration file not found: $CONFIG_FILE"
                    exit 1
                fi
            else
                echo "Error: $arg requires a file path"
                exit 1
            fi
            ;;
        --rootfs-overlay)
            # Next argument should be the directory path
            CONTAINER_ARGS+=("$arg")
            i=$((i + 1))
            if [[ $i -lt ${#ARGS[@]} ]]; then
                OVERLAY_DIR="${ARGS[$i]}"
                if [[ -d "$OVERLAY_DIR" ]]; then
                    # Convert to absolute path
                    OVERLAY_ABS=$(realpath "$OVERLAY_DIR")
                    OVERLAY_CONTAINER="/workspace/$(basename "$OVERLAY_DIR")"
                    DOCKER_ARGS+=(
                        "--volume" "${OVERLAY_ABS}:${OVERLAY_CONTAINER}:ro"
                    )
                    # Use container path in arguments
                    CONTAINER_ARGS+=("$OVERLAY_CONTAINER")
                else
                    echo "Error: Rootfs overlay directory not found: $OVERLAY_DIR"
                    exit 1
                fi
            else
                echo "Error: --rootfs-overlay requires a directory path"
                exit 1
            fi
            ;;
        --package-dir)
            # Next argument should be the directory path containing .deb files
            CONTAINER_ARGS+=("$arg")
            i=$((i + 1))
            if [[ $i -lt ${#ARGS[@]} ]]; then
                PKG_DIR="${ARGS[$i]}"
                if [[ -d "$PKG_DIR" ]]; then
                    # Convert to absolute path
                    PKG_ABS=$(realpath "$PKG_DIR")
                    PKG_CONTAINER="/workspace/$(basename "$PKG_DIR")-packages"
                    DOCKER_ARGS+=(
                        "--volume" "${PKG_ABS}:${PKG_CONTAINER}:ro"
                    )
                    # Use container path in arguments
                    CONTAINER_ARGS+=("$PKG_CONTAINER")
                else
                    echo "Error: Package directory not found: $PKG_DIR"
                    exit 1
                fi
            else
                echo "Error: --package-dir requires a directory path"
                exit 1
            fi
            ;;
        *)
            # Regular argument, pass through as-is
            CONTAINER_ARGS+=("$arg")
            ;;
    esac
    i=$((i + 1))
done

# Run the Docker container
exec docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}:${IMAGE_TAG}" "${CONTAINER_ARGS[@]}"
