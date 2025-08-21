# RISC-V 우분투 24.04 소스 빌드 및 이미지 생성 가이드

이 문서는 `build_riscv_ubuntu.sh` 스크립트를 사용하여 QEMU에서 부팅 가능한 RISC-V용 우분투 24.04 이미지를 소스 코드로부터 빌드하는 전체 과정을 설명합니다.

## 1. 개요

이 프로세스의 목표는 특정 패키지들을 소스에서 직접 빌드하여 포함하는 커스텀 우분투 이미지를 생성하는 것입니다. 전체 과정은 단일 셸 스크립트로 자동화되어 있어 재현성과 신뢰성이 높습니다.

**주요 특징:**
- **자동화**: `sudo ./build_riscv_ubuntu.sh` 명령 하나로 모든 과정이 실행됩니다.
- **모듈화**: 각 기능(루트FS 생성, 빌드, 이미지 생성 등)이 독립된 함수로 구현되어 이해하기 쉽습니다.
- **안정성**: 빌드 실패 시 중간부터 재시작할 수 있도록 멱등성(idempotency)을 보장합니다.
- **재현성**: 상세한 로그와 빌드 환경 정보를 기록하여 동일한 결과를 재현하기 용이합니다.

## 2. 사용법

### 2.1. 사전 준비

- **호스트 시스템**: Ubuntu 24.04 (x86_64) 권장
- **RISC-V 커널**: QEMU 부팅에 사용할 `Image` 파일과 `initrd.img` (선택 사항) 파일이 필요합니다. 이들은 스크립트로 생성되지 않으므로 미리 준비해야 합니다.

### 2.2. 스크립트 실행

스크립트가 있는 디렉토리에서 아래 명령을 실행합니다.

```bash
sudo bash build_riscv_ubuntu.sh
```

### 2.3. 설정 변경 (선택 사항)

스크립트 실행 전, 환경 변수를 설정하여 빌드 옵션을 변경할 수 있습니다.

```bash
# 빌드할 패키지 목록 변경
export PKGS="bash coreutils binutils"

# 특정 패키지의 버전 고정 (예: coreutils 9.4-3ubuntu2 버전으로 빌드)
export PKG_VER_coreutils="9.4-3ubuntu2"

# 작업 디렉토리 변경
export WORKDIR="/data/riscv-build"

# 생성될 이미지 이름 변경
export IMG_NAME="my-custom-ubuntu.qcow2"

# 부팅에 사용할 커널 경로 지정
export KERNEL="/path/to/your/Image"
export INITRD="/path/to/your/initrd.img"

sudo bash build_riscv_ubuntu.sh
```

## 3. 빌드 프로세스 상세 설명

스크립트는 `main` 함수를 통해 다음 단계들을 순차적으로 실행합니다.

### 1단계: 환경 준비 (`ensure_host_deps`, `prepare_dirs`)
- **목적**: 빌드에 필요한 모든 도구와 작업 공간을 준비합니다.
- **수행 내용**:
  - `apt-get`을 통해 `debootstrap`, `qemu-user-static`, `build-essential` 등 호스트 시스템에 필요한 패키지를 설치합니다.
  - `WORKDIR` 경로(`기본값: /srv/rvbuild`) 아래에 로그(`logs`), 빌드 결과물(`out`), 레코드(`records`) 등을 저장할 하위 디렉토리를 생성합니다.

### 2단계: 타겟 루트FS 생성 (`make_target_rootfs`)
- **목적**: 최종적으로 QEMU 이미지에 들어갈 우분투 시스템의 뼈대를 만듭니다.
- **수행 내용**:
  - `debootstrap`을 사용하여 지정된 우분투 버전(`SUITE`)과 아키텍처(`ARCH`)에 맞는 최소 시스템을 다운로드합니다. (`--foreign` 옵션으로 1단계만 수행)
  - `qemu-riscv64-static`을 복사하여 x86_64 호스트에서도 RISC-V 바이너리를 실행할 수 있는 chroot 환경을 구성합니다.
  - `chroot` 환경 안에서 `debootstrap --second-stage`를 실행하여 시스템 설치를 완료합니다.
  - `apt` 저장소 정보(`sources.list`)를 설정하고, `openssh-server`, `systemd` 등 기본 운영에 필요한 패키지들을 설치합니다.
  - `root` 비밀번호 설정, 호스트 이름 지정, 네트워크 설정 등 기본적인 시스템 구성을 완료합니다.
  - 이 단계는 이미 완료되었다면 건너뛰므로, 빌드 실패 시 시간을 절약할 수 있습니다.

### 3단계: 빌더(Builder) 환경 생성 및 스냅샷 (`make_builder_base`)
- **목적**: 소스 코드를 컴파일할 격리되고 깨끗한 환경을 만듭니다.
- **수행 내용**:
  - 타겟 루트FS와 유사하게 `debootstrap`으로 빌드 전용 chroot 환경(`builder-base`)을 만듭니다.
  - `build-essential`, `devscripts` 등 패키지 빌드에 필요한 도구들을 설치합니다.
  - 모든 설정이 완료된 빌더 환경을 `builder-base.tar` 파일로 압축하여 **스냅샷**을 만듭니다.
  - 이 스냅샷 덕분에 각 패키지를 빌드하기 직전에 항상 동일한 상태의 깨끗한 빌더 환경으로 빠르게 복원할 수 있습니다.

### 4단계: 소스 코드 빌드 및 설치 (`build_and_install_loop`)
- **목적**: `PKGS` 변수에 지정된 모든 패키지를 소스에서 빌드하고 타겟 루트FS에 설치합니다.
- **수행 내용**:
  - `PKGS` 목록의 각 패키지에 대해 다음을 반복합니다.
    1.  **빌더 초기화 (`reset_builder`)**: `builder-base.tar` 스냅샷을 풀어 `builder` 디렉토리를 생성합니다.
    2.  **소스 빌드 (`build_one`)**:
        - `chroot`로 `builder` 환경에 진입합니다.
        - `apt-get build-dep`로 빌드 의존성 패키지들을 설치합니다.
        - `apt-get source`로 패키지의 소스 코드를 다운로드합니다. (버전이 지정되었다면 해당 버전으로)
        - `dpkg-buildpackage`를 실행하여 `.deb` 패키지 파일을 생성합니다.
        - 생성된 `.deb` 파일들을 `OUTDIR`로 복사합니다.
    3.  **타겟에 설치 (`install_into_target`)**:
        - 빌드된 `.deb` 파일이 있는 `OUTDIR`를 타겟 루트FS 내부(`host-out`)에 `mount --bind`로 연결합니다. (파일 복사보다 효율적)
        - `chroot`로 타겟 루트FS에 진입하여 `dpkg -i` 명령으로 `.deb` 파일을 설치합니다. 의존성 문제가 발생하면 `apt-get -f install`로 자동 해결합니다.
        - 마운트를 해제합니다.

### 5단계: QEMU 이미지 생성 (`make_qcow2`)
- **목적**: 모든 패키지 설치가 완료된 타겟 루트FS를 부팅 가능한 디스크 이미지로 만듭니다.
- **수행 내용**:
  - `truncate`로 빈 raw 이미지 파일을 생성하고 `mkfs.ext4`로 포맷합니다.
  - 이미지를 루프백 마운트한 뒤, `rsync`를 사용해 타겟 루트FS의 모든 내용을 복사합니다.
  - `fstab` 파일을 생성하여 부팅 시 루트 파티션을 마운트하도록 설정합니다.
  - `qemu-img convert` 명령으로 raw 이미지를 효율적인 `qcow2` 포맷으로 변환합니다.

### 6단계: 부팅 및 기록 (`print_boot_help`, `record_minimal_logs`)
- **목적**: 사용자에게 부팅 방법을 안내하고, 빌드 재현을 위한 정보를 저장합니다.
- **수행 내용**:
  - 생성된 이미지로 QEMU를 부팅하는 예시 명령어를 출력합니다.
  - 타겟 및 빌더 루트FS의 `dpkg -l` (설치된 패키지 목록), `apt-cache policy` (저장소 정책) 등의 정보를 `records` 디렉토리에 저장합니다.

## 4. 커스터마이징

- **패키지 추가/제거**: 스크립트 상단의 `PKGS` 변수 목록을 수정하여 빌드할 패키지를 자유롭게 변경할 수 있습니다.
- **ISA 툴체인 교체**: `PKGS`에 `gcc`, `glibc`, `binutils` 등을 포함하여 자신만의 툴체인을 빌드하고 이미지에 포함시킬 수 있습니다. `glibc`와 `gcc`는 상호 의존성이 있으므로 빌드 순서에 주의가 필요할 수 있습니다.
- **버전 고정**: `export PKG_VER_<패키지명>=<버전>` 환경 변수를 설정하여 특정 버전의 패키지를 소스 빌드할 수 있습니다. 이는 연구 및 디버깅에 매우 유용합니다.