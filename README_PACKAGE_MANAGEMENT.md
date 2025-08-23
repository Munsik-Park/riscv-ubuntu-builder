# RISC-V Ubuntu 빌드 패키지 관리 시스템

## 개요

RISC-V Ubuntu 빌드 시스템에서 패키지 목록을 외부 파일로 관리하는 시스템입니다.

## 파일 구조

```
riscv-ubuntu-builder/
├── build_packages.list      # 빌드할 패키지 목록
├── build_parallel.sh        # 병렬 빌드 스크립트 (수정됨)
├── manage_packages.sh       # 패키지 관리 도구 (새로 추가)
└── README_PACKAGE_MANAGEMENT.md  # 이 문서
```

## 주요 파일 설명

### 1. build_packages.list
빌드할 패키지 목록을 정의하는 파일입니다.

```bash
# RISC-V Ubuntu Build Package List
# 
# 이 파일은 빌드할 패키지 목록을 정의합니다.
# - 한 줄에 하나의 패키지명
# - '#'로 시작하는 줄은 주석
# - 빈 줄은 무시됨

# 현재 빌드 중인 패키지들 (3개)
binutils
iputils-ping 
openssh-server

# 추가로 빌드해야 할 패키지들 (5개)
xz-utils
iproute2
netbase
ca-certificates
gdb
```

### 2. 수정된 build_parallel.sh
- 하드코딩된 패키지 목록을 제거
- `build_packages.list`에서 동적으로 패키지 로드
- 패키지명 유효성 검사 추가
- 오류 처리 강화

### 3. manage_packages.sh (새로 추가)
패키지 목록을 쉽게 관리할 수 있는 도구입니다.

## 사용법

### 1. 기본 빌드 실행

```bash
# 5개 패키지를 동시에 빌드
sudo ./build_parallel.sh 5

# 기본 2개 패키지 동시 빌드
sudo ./build_parallel.sh
```

### 2. 패키지 목록 관리

```bash
# 현재 패키지 목록 확인
./manage_packages.sh list

# 패키지 추가
./manage_packages.sh add vim

# 패키지 제거
./manage_packages.sh remove gdb

# 패키지 목록 유효성 검사
./manage_packages.sh validate

# 빌드 상태 확인
./manage_packages.sh status
```

### 3. 프리셋 사용

```bash
# 원래 15개 패키지로 리셋
./manage_packages.sh reset-original

# 최소 필수 패키지만 남기기
./manage_packages.sh reset-minimal
```

### 4. 환경변수 사용

```bash
# 다른 패키지 목록 파일 사용
PACKAGE_LIST_FILE=/path/to/custom.list ./build_parallel.sh 3

# 빌드 기본 디렉터리 변경
BUILD_BASE_DIR=/custom ./build_parallel.sh 2
```

## 현재 목표 패키지 (초기 15개)

### ✅ chroot에 이미 포함 (7개)
- bash, coreutils, grep, sed, findutils, tar, util-linux

### 🔄 현재 빌드 설정 (8개)
1. **binutils** - GNU 바이너리 유틸리티
2. **iputils-ping** - 네트워크 ping 도구  
3. **openssh-server** - SSH 서버
4. **xz-utils** - XZ 압축 도구
5. **iproute2** - 네트워크 관리 도구
6. **netbase** - 네트워크 기본 파일
7. **ca-certificates** - SSL 인증서
8. **gdb** - GNU 디버거

## 빌드 상태 확인

```bash
./manage_packages.sh status
```

출력 예시:
```
[12:06:51] Build package status:
[12:06:51] Current build packages:
 1. binutils
 2. iputils-ping
 3. openssh-server
 4. xz-utils
 5. iproute2
 6. netbase
 7. ca-certificates
 8. gdb

[12:06:51] Total: 8 packages

[12:06:51] Checking build directories...
  ✅ binutils (built)         # .deb 파일이 생성됨
  🔄 iputils-ping (building)   # 현재 빌드 중
  ⏳ netbase (pending)        # 빌드 대기
```

## 고급 사용법

### 패키지 목록 파일 형식

```bash
# 주석 지원
# - '#'으로 시작하는 줄은 무시
# - 빈 줄도 무시

package-name          # 기본 패키지명
package-with-dash     # 대시 포함 가능
package.with.dot      # 점 포함 가능  
package+extension     # 플러스 포함 가능
```

### 패키지명 유효성 규칙

- 알파벳, 숫자로 시작
- 대시(-), 점(.), 플러스(+) 포함 가능
- 공백이나 특수문자 불가

### 백업 및 복구

```bash
# 현재 설정 백업
cp build_packages.list build_packages.list.backup

# 백업에서 복구
cp build_packages.list.backup build_packages.list
```

## 문제 해결

### 1. 패키지 목록 파일이 없는 경우
```bash
./build_parallel.sh
# 오류: Package list file not found: /path/to/build_packages.list
```
**해결**: `build_packages.list` 파일을 생성하거나 `PACKAGE_LIST_FILE` 환경변수 설정

### 2. 잘못된 패키지명
```bash
./manage_packages.sh validate
# 오류: Invalid package name: 'wrong-package@name'
```
**해결**: 패키지명에서 특수문자 제거

### 3. 빌드 실패
```bash
# 개별 패키지 빌드 테스트
sudo ./build_single_package.sh package-name

# 로그 확인
tail -f /srv/rvbuild-package-name/logs/20_build_package-name.log
```

## 예제 시나리오

### 시나리오 1: 새 패키지 추가
```bash
# vim 패키지 추가
./manage_packages.sh add vim

# 확인
./manage_packages.sh list

# 빌드
sudo ./build_parallel.sh 3
```

### 시나리오 2: 최소 환경으로 리셋
```bash
# 최소 패키지만 남기기
./manage_packages.sh reset-minimal

# 필요한 패키지 추가
./manage_packages.sh add curl
./manage_packages.sh add wget

# 빌드
sudo ./build_parallel.sh 2
```

### 시나리오 3: 커스텀 패키지 목록
```bash
# 새 목록 파일 생성
cat > custom_packages.list << EOF
curl
wget
nano
htop
EOF

# 커스텀 목록으로 빌드
PACKAGE_LIST_FILE=custom_packages.list sudo ./build_parallel.sh 4
```

---

**참고**: 이 시스템은 기존 빌드 프로세스와 완전히 호환되며, 기존 스크립트들의 동작을 변경하지 않습니다.