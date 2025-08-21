
# Ubuntu 24.04 RISC‑V Image — Source‑Built (QEMU, Research Profile)

This document is a **minimal, research‑oriented** process to build a bootable **Ubuntu 24.04 (noble) for RISC‑V** that:
1) runs on **QEMU** (not tied to a specific board),  
2) includes **APT/SSH** out of the box (Python installable post‑boot),  
3) allows **replacing ISA‑related packages** (e.g., gcc/glibc/binutils/qemu) with your **own source builds**, and  
4) builds **from official repository sources** for a **specific version** (24.04) **without mirroring** for now (a mirror/snapshot can be added later).

> Scope is **research**: security hardening, extensive QA, and multi‑arch testing are intentionally minimized to keep the flow simple and reproducible enough.

---

## 0) Host prerequisites

Host: Ubuntu 22.04/24.04 **amd64** (or equivalent), with sudo.

```bash
sudo apt-get update
sudo apt-get install -y \
  debootstrap qemu-user-static binfmt-support qemu-system-misc \
  build-essential devscripts debhelper fakeroot quilt \
  ubuntu-keyring debian-archive-keyring rsync e2fsprogs \
  ca-certificates curl
```

Optional (helps later): `ccache`, `git`, `pkg-config`.

Environment variables:
```bash
export SUITE=noble
export ARCH=riscv64
export MIRROR=http://ports.ubuntu.com/ubuntu-ports
```

---

## 1) Target rootfs (the image contents)

Create a minimal rootfs using **official repositories** (no local mirror yet).

```bash
sudo mkdir -p /srv/target-rootfs
sudo debootstrap --arch=$ARCH --foreign $SUITE /srv/target-rootfs $MIRROR
sudo cp /usr/bin/qemu-riscv64-static /srv/target-rootfs/usr/bin/
sudo chroot /srv/target-rootfs /debootstrap/debootstrap --second-stage
```

APT sources (binary + **source** lines enabled so you can fetch the exact sources):
```bash
cat <<'EOF' | sudo tee /srv/target-rootfs/etc/apt/sources.list
deb http://ports.ubuntu.com/ubuntu-ports noble main universe multiverse restricted
deb http://ports.ubuntu.com/ubuntu-ports noble-updates main universe multiverse restricted
deb http://ports.ubuntu.com/ubuntu-ports noble-security main universe multiverse restricted
deb-src http://ports.ubuntu.com/ubuntu-ports noble main universe multiverse restricted
deb-src http://ports.ubuntu.com/ubuntu-ports noble-updates main universe multiverse restricted
deb-src http://ports.ubuntu.com/ubuntu-ports noble-security main universe multiverse restricted
EOF

sudo chroot /srv/target-rootfs apt-get update
```

Minimal runtime (APT/SSH ready; Python installable later):
```bash
sudo chroot /srv/target-rootfs apt-get install -y \
  systemd-sysv openssh-server netbase iproute2 iputils-ping \
  ca-certificates sudo locales tzdata vim-tiny less

sudo chroot /srv/target-rootfs locale-gen en_US.UTF-8
echo ubuntu-rv | sudo tee /srv/target-rootfs/etc/hostname >/dev/null
echo "root:root" | sudo chroot /srv/target-rootfs chpasswd
sudo chroot /srv/target-rootfs systemctl enable ssh

# simple DHCP networking via ifupdown (netplan/systemd-networkd also OK)
cat <<'EOF' | sudo tee /srv/target-rootfs/etc/network/interfaces.d/eth0
auto eth0
iface eth0 inet dhcp
EOF
```

> After first boot you can install Python with:  
> `apt-get update && apt-get install -y python3 python3-pip`

---

## 2) Builder chroot (per‑package source builds)

We’ll **build packages from source** in a clean chroot, then install the resulting `.deb` into the target rootfs.  
For simplicity (no mirror yet), we **pin exact versions** from official repositories when needed.

Create a **base builder chroot** and save a tar snapshot for quick restores:
```bash
sudo mkdir -p /srv/builder-base
sudo debootstrap --arch=$ARCH --foreign $SUITE /srv/builder-base $MIRROR
sudo cp /usr/bin/qemu-riscv64-static /srv/builder-base/usr/bin/
sudo chroot /srv/builder-base /debootstrap/debootstrap --second-stage

cat <<'EOF' | sudo tee /srv/builder-base/etc/apt/sources.list
deb http://ports.ubuntu.com/ubuntu-ports noble main universe multiverse restricted
deb http://ports.ubuntu.com/ubuntu-ports noble-updates main universe multiverse restricted
deb http://ports.ubuntu.com/ubuntu-ports noble-security main universe multiverse restricted
deb-src http://ports.ubuntu.com/ubuntu-ports noble main universe multiverse restricted
deb-src http://ports.ubuntu.com/ubuntu-ports noble-updates main universe multiverse restricted
deb-src http://ports.ubuntu.com/ubuntu-ports noble-security main universe multiverse restricted
EOF

sudo chroot /srv/builder-base apt-get update
sudo chroot /srv/builder-base apt-get install -y \
  build-essential devscripts debhelper fakeroot quilt \
  ca-certificates pkg-config

# Freeze a clean snapshot to reset for each package build
sudo tar -C /srv -cpf /srv/builder-base.tar builder-base
```

**Version pinning without a mirror** (research‑grade):  
- Prefer explicit version on CLI when available:  
  - `apt-get source pkg=VERSION`  
  - `apt-get install pkg=VERSION` (for deps)
- Record the selected versions (see §6 logs).  
- Later, when you introduce a mirror/snapshot, you’ll get strict reproducibility.

---

## 3) Build from source → install into target

White‑list the packages you want to self‑build (you can start small and expand).  
**APT/SSH core** already installed above; here are examples (userland & ISA‑related).

```bash
export PKGS="bash coreutils grep sed findutils tar xz-utils e2fsprogs util-linux \
             iproute2 netbase ca-certificates \
             binutils gcc gdb"   # add glibc/linux later if you plan to replace them
```

Helper: build one package in a **fresh builder chroot** and install artifacts into **target rootfs**.  
This keeps builds isolated and allows **ISA toolchain replacement** at your pace.

```bash
build_one() {
  local pkg="$1"
  # reset builder chroot
  sudo rm -rf /srv/builder && sudo mkdir -p /srv/builder
  sudo tar -C /srv -xpf /srv/builder-base.tar
  sudo mv /srv/builder-base /srv/builder

  # (Optional) exact version pin if you know it, e.g. pkg=1.2.3-1ubuntu1
  local ver_clause=""
  # ver_clause="=${VERSION}"

  sudo chroot /srv/builder bash -lc "
    set -e
    apt-get update
    apt-get build-dep -y ${pkg}
    apt-get source ${pkg}${ver_clause}
    cd \$(find . -maxdepth 1 -type d -name '${pkg}-*' | sort | head -n1)
    dpkg-buildpackage -us -uc -b
  "

  # collect .deb
  mkdir -p /tmp/out
  sudo find /srv/builder -maxdepth 1 -type f -name '*.deb' -exec cp {} /tmp/out/ \;

  # install into target rootfs (resolve remaining deps from official repo)
  sudo mkdir -p /srv/target-rootfs/host-out
  sudo mount --bind /tmp/out /srv/target-rootfs/host-out
  sudo cp /usr/bin/qemu-riscv64-static /srv/target-rootfs/usr/bin/
  sudo chroot /srv/target-rootfs bash -lc "
    set -e
    dpkg -i /host-out/*.deb || apt-get -f -y install
  "
  sudo umount /srv/target-rootfs/host-out
}

# loop through the list
for p in $PKGS; do
  rm -rf /tmp/out && mkdir -p /tmp/out
  build_one "$p"
done
```

### ISA toolchain replacement (gcc/glibc/binutils)
- Start by replacing **binutils** and **gdb** (simple).  
- For **gcc/glibc**, expect a **bootstrap sequence** (stage1 → minimal glibc headers/startfiles → gcc stage2 → glibc full → gcc final).  
- You can keep the rest of userland from official binaries while iterating on your **compiler/ISA experiments**.

> Research tip: If replacing glibc/gcc is not immediately required, keep them from official repos first, validate QEMU image and workflow, **then** iterate on toolchain packages.

---

## 4) Create a bootable qcow2 image

```bash
IMG=ubuntu-rv.qcow2
SIZE=4G
TMP=$(mktemp -d)

truncate -s $SIZE /tmp/rv.raw
mkfs.ext4 -F /tmp/rv.raw
sudo mount -o loop /tmp/rv.raw $TMP
sudo rsync -aHAX /srv/target-rootfs/ $TMP/
echo "/dev/vda / ext4 defaults 0 1" | sudo tee $TMP/etc/fstab >/dev/null
sudo umount $TMP

qemu-img convert -f raw -O qcow2 /tmp/rv.raw $IMG
rm -rf $TMP /tmp/rv.raw
```

Use a prebuilt kernel/initrd (simplest for QEMU research). Later you can also build your own kernel if desired.

```bash
KERNEL=./Image      # path to a working RISC-V kernel
INITRD=./initrd.img # optional if using initramfs

qemu-system-riscv64 -M virt -m 2048 \
  -kernel $KERNEL -initrd $INITRD \
  -append "root=/dev/vda rw console=ttyS0" \
  -drive file=$IMG,format=qcow2,if=virtio \
  -device virtio-net-device,netdev=n0 -netdev user,id=n0,hostfwd=tcp::2222-:22 \
  -nographic
# SSH after boot:  ssh -p 2222 root@127.0.0.1   (password: root)
```

---

## 5) After boot

- Networking via user‑mode QEMU with host‑forward: `ssh -p 2222 root@127.0.0.1`
- Install Python on demand:
  ```bash
  apt-get update && apt-get install -y python3 python3-pip
  ```
- Replace/upgrade your ISA toolchain packages by transferring new `.deb` or by building inside the image (not recommended for reproducibility) or via the **builder chroot** path above.

---

## 6) Minimal reproducibility notes (no mirror yet)

Even without a mirror/snapshot, record these to approximate reproducibility:

```bash
# inside both builder and target rootfs
apt-cache policy | tee /root/apt-cache-policy.txt
dpkg -l | tee /root/dpkg-l.txt
cat /etc/apt/sources.list | tee /root/sources.list.copy
```

When you later introduce a **mirrored snapshot**, lock the suite to that snapshot and drop explicit `=VERSION` clauses; full reproducibility becomes straightforward.

---

## 7) What this satisfies (mapping to your requirements)

1) **RISC‑V Ubuntu distribution** → Noble riscv64 userland, packaged into a QEMU‑bootable image.  
2) **Build from official source (24.04)** → `deb-src` enabled; `apt-get source`, `dpkg-buildpackage` pipeline; version pin supported without mirroring.  
3) **QEMU (no specific board)** → Uses `qemu-system-riscv64 -M virt` flow.  
4) **APT/SSH supported; Python post‑install** → openssh-server + APT configured; Python install line provided.  
5) **Research purpose** → minimized QA/hardening; focuses on repeatable steps and logs.  
6) **ISA package replacement** → clean builder chroot per package; binutils/gdb easy; gcc/glibc via staged bootstrap when needed.

---

## 8) Next steps (optional)

- Introduce a **mirror/snapshot** (aptly/reprepro) to pin versions exactly.  
- Add a lightweight **build queue** script to iterate a package list and keep build logs.  
- If you plan to replace **gcc/glibc**, add a dedicated bootstrap script (`stage1 → headers → stage2 → glibc → final`).

