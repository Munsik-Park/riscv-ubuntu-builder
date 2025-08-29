#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
REL=${REL:-noble}
ARCH=${ARCH:-riscv64}
IMAGE_SIZE=${IMAGE_SIZE:-4G}
# Assume script is run from the project root, e.g., /home/ubuntu/riscv-minimal-build
BASE_DIR=$(pwd)

# --- Paths ---
OUT_DIR="${BASE_DIR}/out"
IMAGE_DIR="${OUT_DIR}/images"
CONFIG_DIR="${BASE_DIR}/configs"
REPO_DIR="${BASE_DIR}/repo/public"

ROOTFS_TAR="${OUT_DIR}/rootfs-${REL}-${ARCH}.tar"
ROOTFS_IMG="${OUT_DIR}/rootfs-${REL}-${ARCH}.img"
FINAL_QCOW2="${IMAGE_DIR}/ubuntu-${REL}-${ARCH}-minimal.qcow2"
SOURCES_LIST="${CONFIG_DIR}/mmdebstrap.sources.list"
REPO_GPG_KEY="${REPO_DIR}/aptly_repo_signing.key"

# --- Pre-flight checks ---
if [[ ! -f "${REPO_GPG_KEY}" ]]; then
    echo "Error: Repository GPG key not found at ${REPO_GPG_KEY}" >&2
    echo "Hint: Run '10_aptly_mirror_freeze.sh' which creates the key during the first publish." >&2
    exit 1
fi

# --- Main Logic ---
echo "==> Creating directories..."
mkdir -p "${IMAGE_DIR}"
mkdir -p "${CONFIG_DIR}"

# Create sources.list for mmdebstrap, pointing to our local repository.
# The GPG key will be copied into the chroot via a hook.
echo "==> Generating sources.list for mmdebstrap..."
cat > "${SOURCES_LIST}" <<EOF
deb [signed-by=/usr/share/keyrings/riscv-build.gpg] file://${REPO_DIR} ${REL} main
EOF

# Create rootfs tarball using mmdebstrap.
echo "==> Building rootfs with mmdebstrap..."
sudo mmdebstrap \
  --arch="${ARCH}" \
  --variant=minbase \
  --components=main \
  --aptopt='Acquire::Languages "none";' \
  --include=systemd,openssh-server,netbase,iproute2,ca-certificates,ubuntu-keyring \
  --customize-hook="cp '${REPO_GPG_KEY}' '\$1/usr/share/keyrings/riscv-build.gpg'" \
  --sources-list="${SOURCES_LIST}" \
  "${REL}" \
  "${ROOTFS_TAR}"

# Create a raw disk image, format it, and mount it.
echo "==> Creating and mounting disk image..."
truncate -s "${IMAGE_SIZE}" "${ROOTFS_IMG}"
mkfs.ext4 -F "${ROOTFS_IMG}"

MOUNT_POINT=$(mktemp -d)
# Setup a trap to ensure we unmount and clean up on exit/error.
trap 'echo "==> Cleaning up..."; sudo umount "${MOUNT_POINT}" &>/dev/null || true; rmdir "${MOUNT_POINT}";' EXIT

sudo mount -o loop "${ROOTFS_IMG}" "${MOUNT_POINT}"

# Extract the rootfs into the mounted image.
echo "==> Extracting rootfs to disk image..."
sudo tar -xpf "${ROOTFS_TAR}" -C "${MOUNT_POINT}"
sudo umount "${MOUNT_POINT}" # Unmount explicitly before converting

# Convert the raw image to QCOW2 format.
echo "==> Converting image to QCOW2 format..."
qemu-img convert -f raw -O qcow2 "${ROOTFS_IMG}" "${FINAL_QCOW2}"

# Clean up intermediate files.
echo "==> Cleaning up intermediate files..."
rm -f "${ROOTFS_TAR}" "${ROOTFS_IMG}"

echo "==> Image creation complete!"
echo "Image available at: ${FINAL_QCOW2}"
