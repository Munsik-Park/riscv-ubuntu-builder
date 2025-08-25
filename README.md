# RISC-V Ubuntu QEMU 네이티브 패키지 빌더

Ubuntu RISC-V 아키텍처용 커스텀 패키지를 QEMU VM에서 네이티브로 빌드하는 자동화된 시스템입니다.

## 주요 특징

- **QEMU 네이티브 빌드**: chroot 대신 완전한 RISC-V VM 환경에서 빌드
- **완전한 격리**: 각 패키지별 독립적인 VM 환경
- **대규모 병렬 처리**: 패키지별 독립 QEMU VM으로 무제한 확장 가능
- **자동화**: 스크립트 하나로 전체 프로세스 실행
- **재현성**: VM 스냅샷으로 동일한 빌드 환경 보장

## 아키텍처 개요

### QEMU 스냅샷 기반 빌드 시스템

1. **베이스 이미지 생성**: Ubuntu RISC-V 기본 시스템 구축 (1회)
2. **스냅샷 생성**: 베이스 이미지에서 패키지별 스냅샷 생성
3. **개별 QEMU 실행**: 각 패키지마다 독립된 QEMU VM 실행
4. **네이티브 빌드**: 각 VM에서 단일 패키지만 빌드 수행
5. **병렬 처리**: 동시에 여러 QEMU VM 실행 (1000개 패키지 = 1000개 QEMU)

### 디렉터리 구조

```
/srv/
├── qemu-base/              # 베이스 Ubuntu RISC-V 이미지
│   ├── ubuntu-riscv-base.qcow2
│   ├── fw_jump.elf         # RISC-V 펌웨어
│   └── uboot.elf           # U-Boot 부트로더
├── qemu-vms/               # 패키지별 VM 이미지
│   ├── binutils/
│   │   ├── ubuntu-binutils.qcow2
│   │   ├── start-vm.sh
│   │   └── vm-config.json
│   └── tar/
│       ├── ubuntu-tar.qcow2
│       ├── start-vm.sh
│       └── vm-config.json
├── qemu-builds/            # 빌드 작업 디렉터리
│   └── binutils/
│       ├── logs/
│       └── out/            # 생성된 .deb 패키지
└── qemu-snapshots/         # VM 스냅샷 저장소
    └── iputils-ping/
        └── ubuntu-iputils-ping.qcow2
```

## 사용 방법

### 1. 단일 패키지 빌드

#### VM 이미지 생성
```bash
# 패키지용 VM 이미지 생성 (한 번만 실행)
sudo ./build_qemu_vm_image.sh <package_name>

# 예시
sudo ./build_qemu_vm_image.sh binutils
```

#### 패키지 빌드 실행
```bash
# VM에서 패키지 빌드
./build_in_qemu_vm.sh <package_name>

# 예시
./build_in_qemu_vm.sh binutils
```

### 2. 병렬 빌드

```bash
# 2개 패키지 동시 빌드 (기본값)
sudo ./build_qemu_parallel.sh

# 5개 패키지 동시 빌드
sudo ./build_qemu_parallel.sh 5

# 단일 패키지 순차 빌드
sudo ./build_qemu_parallel.sh 1
```

### 3. VM 관리

```bash
# VM 목록 확인
./qemu_vm_manager.sh list

# VM 시작
./qemu_vm_manager.sh start <package_name>

# VM에 SSH 연결
./qemu_vm_manager.sh connect <package_name>

# VM 중지
./qemu_vm_manager.sh stop <package_name>

# VM 이미지 삭제
./qemu_vm_manager.sh clean <package_name>
```

## 주요 스크립트

### VM 관리 스크립트
- **`build_qemu_vm_image.sh`** - 패키지별 부팅 가능한 VM 이미지 생성
- **`qemu_vm_manager.sh`** - VM 라이프사이클 관리 (생성, 시작, 중지, 삭제)
- **`start_build_vm.sh`** - VM 시작 전용 스크립트

### 빌드 실행 스크립트
- **`build_in_qemu_vm.sh`** - SSH를 통한 VM 내부 패키지 빌드
- **`build_qemu_single.sh`** - 단일 패키지 빌드 (VM 생성 + 빌드)
- **`build_qemu_parallel.sh`** - 여러 패키지 병렬 빌드

### 설정 및 유틸리티
- **`qemu_config.sh`** - QEMU VM 리소스 설정 (CPU, Memory, Disk)
- **`monitor_qemu_builds.sh`** - 빌드 프로세스 모니터링
- **`clean_qemu_builds.sh`** - 빌드 환경 정리

## 빌드 패키지 관리

### 패키지 목록 파일
- **`build_packages.list`** - 빌드할 패키지 목록 정의
- **`manage_packages.sh`** - 패키지 목록 관리 도구

### 패키지 목록 편집
```bash
# 현재 빌드 패키지 확인
./manage_packages.sh list

# 패키지 추가
./manage_packages.sh add curl

# 패키지 제거
./manage_packages.sh remove gdb

# 빌드 상태 확인
./manage_packages.sh status
```

## 설정 옵션

### QEMU VM 설정
```bash
# VM별 CPU 코어 수 (기본: 1)
export QEMU_CPUS=2

# VM별 메모리 크기 (기본: 8192MB)
export QEMU_MEMORY=4096

# VM별 디스크 크기 (기본: 8G)
export QEMU_DISK_SIZE=16G

# SSH 베이스 포트 (기본: 2222)
export QEMU_BASE_PORT=3000
```

### 빌드 설정
```bash
# Ubuntu 버전 (기본: noble)
export SUITE=jammy

# 타겟 아키텍처 (기본: riscv64)
export ARCH=riscv64

# Ubuntu 미러 서버
export MIRROR=http://ports.ubuntu.com/ubuntu-ports

# VM 베이스 디렉터리
export VM_BASE_DIR=/custom/qemu-vms
```

## 현재 지원 패키지

현재 `build_packages.list`에 정의된 패키지들:
- **binutils** - GNU 바이너리 유틸리티
- **iputils-ping** - 네트워크 ping 도구
- **openssh-server** - SSH 서버
- **coreutils** - 핵심 시스템 유틸리티
- **tar** - 아카이브 도구

## 빌드 프로세스

### 1단계: 베이스 환경 구축 (1회 실행)
1. **Ubuntu RISC-V 베이스 시스템** 생성
2. **공통 빌드 도구** 설치 (build-essential, devscripts 등)
3. **베이스 이미지 스냅샷** 저장

### 2단계: 패키지별 빌드 (각 패키지마다)
1. **스냅샷 복사**: 베이스 이미지에서 패키지별 스냅샷 생성
2. **개별 QEMU VM 시작**: 독립된 포트로 VM 부팅
3. **단일 패키지 빌드**: 하나의 패키지만 빌드 (1 VM = 1 Package)
4. **의존성 설치**: 패키지별 build-dep 설치
5. **소스 빌드**: `dpkg-buildpackage`로 .deb 생성
6. **결과물 전송**: SSH로 .deb 파일 호스트 복사
7. **VM 종료**: 빌드 완료 후 자동 종료

### 3단계: 대규모 병렬 처리
- **동시 실행**: 여러 패키지 QEMU VM 병렬 실행
- **리소스 격리**: 각 VM이 독립적인 메모리/CPU 사용
- **확장성**: 1000개 패키지 = 1000개 QEMU VM 동시 실행 가능

## 장점

### chroot 대비 장점
- **완전한 격리**: 패키지 빌드 간 상호 간섭 없음
- **네이티브 환경**: RISC-V 네이티브 실행으로 더 안정적
- **확장성**: VM별 리소스 개별 할당 가능
- **디버깅**: VM 콘솔 로그로 문제 진단 용이

### 대규모 병렬 처리
- **무제한 확장**: 패키지 수만큼 QEMU VM 생성 (1:1 매핑)
- **완전한 격리**: 각 패키지가 독립된 VM에서 실행 (상호 간섭 없음)
- **동일한 빌드 방식**: 모든 패키지가 동일한 스냅샷 기반 방식으로 빌드
- **실패 격리**: 하나의 패키지 빌드 실패가 다른 빌드에 전혀 영향 없음
- **리소스 분산**: 각 VM이 독립적인 메모리/CPU/디스크 공간 사용

## 문제 해결

### VM 부팅 실패
```bash
# VM 콘솔 로그 확인
./qemu_vm_manager.sh console <package_name>

# VM 상태 확인
./qemu_vm_manager.sh status
```

### 빌드 실패 디버깅
```bash
# 빌드 로그 확인
tail -f /srv/qemu-builds/<package_name>/logs/build.log

# VM에 직접 연결하여 디버깅
./qemu_vm_manager.sh connect <package_name>
```

### 리소스 부족
```bash
# 현재 리소스 사용량 확인
./qemu_config.sh total 3

# VM 리소스 조정
export QEMU_MEMORY=4096
export QEMU_CPUS=1
```

## 요구사항

- **호스트 시스템**: Ubuntu 24.04 (x86_64) 권장
- **메모리**: 최소 16GB (병렬 빌드 시)
- **디스크**: 패키지당 약 8GB 필요
- **필수 패키지**: qemu-system-misc, qemu-utils, debootstrap

## 라이선스

이 프로젝트는 오픈 소스이며, Ubuntu 및 관련 패키지들의 라이선스를 따릅니다.