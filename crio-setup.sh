#!/bin/bash
set -euo pipefail

# for ocp 1.16.30: podman pull registry.access.redhat.com/ubi9/go-toolset:1.21.13

export KUBECONFIG=/etc/kubernetes/kubeconfig
#ocpversion=4.16.30
k8sversion="$(oc version -o json | jq -r '.serverVersion | "\(.major).\(.minor)"')"
# /usr/bin/crio --version | grep "GoVersion:" | sed -E 's/.*go([0-9.]+).*/\1/'

goversion=$(oc version -o json | jq -r '.serverVersion.goVersion | capture("go(?<ver>[0-9.]+)") | .ver')
INSTALL_COMMAND="dnf install -y make wget gcc gcc-c++ openssl openssl-devel git gpgme-devel libseccomp-devel glibc-static clang-devel device-mapper-devel xz patch"

# Extract major, minor, and patch versions
IFS='.' read -r major minor patch <<< "$goversion"

# Function to check if container image exists and can be pulled
check_and_pull_image() {
    local version=$1
    local image="registry.access.redhat.com/ubi9/go-toolset:${version}"
    echo "Attempting to pull image: $image"
    if podman pull "$image" 2>/dev/null; then
        echo "Successfully pulled image: $image"
        return 0
    else
        echo "Failed to pull image: $image"
        return 1
    fi
}

# Try to find a valid Go version by reducing patch version
found_version=""
current_patch=$patch

while [ $current_patch -ge 0 ]; do
    test_version="${major}.${minor}.${current_patch}"
    if check_and_pull_image "$test_version"; then
        found_version="$test_version"
        break
    fi
    ((current_patch--))
done

# If no version found, exit with error
if [ -z "$found_version" ]; then
    echo "Error: Could not find a pullable Go toolset image for version ${major}.${minor}.x"
    exit 1
fi

echo "Using Go version: $found_version"
goversion="$found_version"

mkdir -p /tmp/buildcrio
pushd /tmp/buildcrio
# make the build env and build crio
podman build -t "buildcrio"  - << EOF
FROM registry.access.redhat.com/ubi9/go-toolset:${goversion}

USER root

RUN ${INSTALL_COMMAND} && \
    wget https://go.dev/dl/go${goversion}.linux-amd64.tar.gz && tar -C /usr/local -xzf go*.tar.gz 
WORKDIR /
RUN git clone https://github.com/cri-o/cri-o.git -b release-${k8sversion}
WORKDIR /cri-o
RUN sed -i  's/240/600/' internal/oci/oci.go
RUN make
RUN pwd
RUN ls -l
EOF

# Extract the compiled crio binary
container_id=$(podman create buildcrio)
podman cp $container_id:/cri-o/bin/crio ./crio
podman rm $container_id
echo "CRI-O binary extracted to ./crio"

# Verify the binary executes properly
echo "Verifying CRI-O binary..."
if ./crio --version; then
    echo "CRI-O binary verification successful"
else
    echo "Error: CRI-O binary failed to execute"
    exit 1
fi

ostree admin unlock --hotfix || true
# Backup the existing CRI-O binary only if no backup exists
CRIO_BINARY="/usr/bin/crio"
BACKUP_PATH="${CRIO_BINARY}.backup"

if [ ! -f "$BACKUP_PATH" ]; then
    if [ -f "$CRIO_BINARY" ]; then
        echo "Backing up existing CRI-O binary to $BACKUP_PATH"
        cp -p "$CRIO_BINARY" "$BACKUP_PATH"
        echo "Backup completed"
    else
        echo "Warning: Existing CRI-O binary not found at $CRIO_BINARY"
    fi
else
    echo "Backup already exists at $BACKUP_PATH, skipping backup"
fi

# Stop CRI-O service
echo "Stopping CRI-O service"
systemctl stop crio

# Replace with the new compiled binary
echo "Replacing CRI-O binary with newly compiled version"
cp ./crio "$CRIO_BINARY"
chmod +x "$CRIO_BINARY"

# Start CRI-O service
echo "Starting CRI-O service"
systemctl start crio

echo "CRI-O binary replaced successfully"
echo "To restore the original binary, run: systemctl stop crio && cp $BACKUP_PATH $CRIO_BINARY && systemctl start crio"
popd

exit 0
