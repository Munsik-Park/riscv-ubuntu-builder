#!/usr/bin/env bash
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "${SCRIPT_DIR}/config.sh"

CHROOT_DIR="/srv/chroot/${REL}-${ARCH}"

echo "Creating sbuild chroot environment for ${ARCH} architecture..."
echo "Chroot directory: ${CHROOT_DIR}"
echo "Local repository: file://${BASE_DIR}/repo/public"

# Create chroot directory if it doesn't exist
sudo mkdir -p /srv/chroot

# Check if chroot already exists
if [[ -d "${CHROOT_DIR}" ]]; then
    echo "Warning: Chroot ${CHROOT_DIR} already exists"
    echo "Remove it first with: sudo rm -rf ${CHROOT_DIR}"
    exit 1
fi

# Export our GPG key to a temporary keyring for debootstrap
TEMP_KEYRING=$(mktemp)
echo "Exporting GPG key for debootstrap..."
gpg --export "${REPO_KEY_ID}" > "${TEMP_KEYRING}"

# Check what build tools we have available
BUILD_TOOLS=""
if grep -q "^build-essential$" "${BASE_DIR}/out/expanded-binaries.txt"; then
    BUILD_TOOLS="build-essential,"
fi
if grep -q "^make$" "${BASE_DIR}/out/expanded-binaries.txt"; then
    BUILD_TOOLS="${BUILD_TOOLS}make,"
fi

# Include only packages we have in our repository
INCLUDE_PACKAGES="ca-certificates,ubuntu-keyring,${BUILD_TOOLS%,}"

echo "Including packages: ${INCLUDE_PACKAGES}"

sudo sbuild-createchroot --arch=${ARCH} \
  --components=${COMP} \
  --include="${INCLUDE_PACKAGES}" \
  --keyring="${TEMP_KEYRING}" \
  ${REL} ${CHROOT_DIR} file://${BASE_DIR}/repo/public

# Clean up temporary keyring
rm -f "${TEMP_KEYRING}"
# pinning: 우리 퍼블리시만 쓰게 (초기에 외부 허용 필요 시 낮은 pin으로 추가)
echo "Setting up APT preferences to use only local repository..."
sudo tee ${CHROOT_DIR}/etc/apt/preferences.d/pin <<'EOF'
Package: *
Pin: origin ""
Pin-Priority: -1
EOF

echo ""
echo "Sbuild chroot created successfully!"
echo "Chroot location: ${CHROOT_DIR}"
echo "Architecture: ${ARCH}"
echo "Distribution: ${REL}"
echo ""
echo "You can now build packages with:"
echo "  sbuild -d ${REL} --arch=${ARCH} --chroot=${REL}-${ARCH} <package>.dsc"
