#!/usr/bin/env bash
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "${SCRIPT_DIR}/config.sh"

REPO_DIR="${BASE_DIR}/repo"
CONFIG_DIR="${BASE_DIR}/configs"
APTLY_CONF="${CONFIG_DIR}/aptly.conf"
PUBLIC_KEY_FILE="${REPO_DIR}/public/aptly_repo_signing.key"

# --- Pre-flight checks and setup ---

# Create a project-local aptly config to make the project self-contained.
echo "==> Creating project-local aptly config at ${APTLY_CONF}"
mkdir -p "${CONFIG_DIR}"
cat > "${APTLY_CONF}" <<EOF
{
  "rootDir": "${REPO_DIR}"
}
EOF

# Ensure the Ubuntu archive keyring is imported into aptly's trusted keys.
# This is required to verify the mirror from ports.ubuntu.com.
# Using a project-local aptly setup, so keys are imported into ${REPO_DIR}/.aptly/
echo "==> Importing Ubuntu archive keys into aptly..."
mkdir -p "${REPO_DIR}/.aptly"
gpg --no-default-keyring --keyring /usr/share/keyrings/ubuntu-archive-keyring.gpg --export \
  | gpg --no-default-keyring --keyring "${REPO_DIR}/.aptly/trustedkeys.gpg" --import

# --- Main Logic ---

# Create a mirror of the Ubuntu Ports repository.
echo "==> Creating and updating aptly mirror for ${REL} ${ARCH}..."
MIRROR_NAME="ubports-${REL}-${COMP}"
if ! aptly -config="${APTLY_CONF}" mirror list -raw | grep -q "^${MIRROR_NAME}$"; then
    aptly -config="${APTLY_CONF}" mirror create -architectures=${ARCH} -with-sources=true ${MIRROR_NAME} \
        http://ports.ubuntu.com/ubuntu-ports ${REL} ${COMP}
fi
aptly -config="${APTLY_CONF}" mirror update ${MIRROR_NAME}

# Freeze the mirror by creating a snapshot.
echo "==> Creating snapshot from mirror..."
SNAP=ubports-${REL}-${COMP}-$(date +%Y%m%d)
# Overwrite snapshot if it exists for today, to make the script idempotent.
aptly -config="${APTLY_CONF}" snapshot drop -force "${SNAP}" >/dev/null 2>&1 || true
aptly -config="${APTLY_CONF}" snapshot create "${SNAP}" from mirror "${MIRROR_NAME}"

# Create a GPG key for signing our local repository if it doesn't exist.
if ! gpg --list-secret-keys "${REPO_KEY_ID}" > /dev/null 2>&1; then
  echo "==> Generating new GPG key for local repository..."
  gpg --batch --passphrase '' --quick-gen-key "${REPO_KEY_ID}"
fi

# Publish the snapshot to create a local file-based APT repository.
# This makes the frozen repository available to other scripts.
PUBLISH_POINT="." # Publish to root of ${REPO_DIR}/public
if aptly -config="${APTLY_CONF}" publish list -raw | grep -q "^${PUBLISH_POINT} \. ${REL}$"; then
    echo "==> Switching already published repository to new snapshot..."
    aptly -config="${APTLY_CONF}" publish switch -gpg-key="${REPO_KEY_ID}" -force "${REL}" "${PUBLISH_POINT}" "${SNAP}"
else
    echo "==> Publishing snapshot for the first time..."
    aptly -config="${APTLY_CONF}" publish snapshot -distribution="${REL}" -component="${COMP}" \
        -gpg-key="${REPO_KEY_ID}" "${SNAP}" "${PUBLISH_POINT}"
fi

# Export the public key so it can be used by clients (e.g., in the chroot/image).
echo "==> Exporting public GPG key to ${PUBLIC_KEY_FILE}..."
mkdir -p "$(dirname "${PUBLIC_KEY_FILE}")"
gpg --export --armor "${REPO_KEY_ID}" > "${PUBLIC_KEY_FILE}"

echo "==> Snapshot published to ${REPO_DIR}/${PUBLISH_POINT}"
