# RISC-V Ubuntu 24.04 (Noble) chroot 기본 패키지 목록

## 통계
- **총 다운로드된 패키지**: 222개
- **실제 설치된 핵심 패키지**: 73개
- **아키텍처**: riscv64
- **Ubuntu 버전**: 24.04 LTS (Noble Numbat)

## 주요 패키지 카테고리

### 1. 시스템 기본 (4개)
- `base-files` - 시스템 기본 파일 및 디렉터리 구조
- `base-passwd` - 기본 사용자 및 그룹 정의
- `bash` - GNU Bourne Again Shell (기본 셸)
- `dash` - POSIX 호환 경량 셸

### 2. 핵심 유틸리티 (7개)
- `coreutils` - GNU 핵심 유틸리티 (ls, cp, mv, chmod 등)
- `findutils` - 파일 검색 유틸리티 (find, xargs)
- `grep` - 텍스트 패턴 검색
- `sed` - 스트림 에디터
- `tar` - 아카이브 유틸리티
- `gzip` - 압축 유틸리티
- `diffutils` - 파일 비교 유틸리티

### 3. 패키지 관리 (4개)
- `dpkg` - Debian 패키지 관리자
- `debconf` - Debian 설정 관리 시스템
- `debianutils` - Debian 관련 유틸리티
- `bsdutils` - BSD 유래 시스템 유틸리티

### 4. 파일 시스템 및 시스템 도구 (4개)
- `e2fsprogs` - ext2/3/4 파일시스템 유틸리티
- `mount` - 파일시스템 마운트 유틸리티
- `util-linux` - Linux 시스템 유틸리티 모음
- `procps` - /proc 파일시스템 유틸리티 (ps, top 등)

### 5. 사용자 관리 및 인증 (3개)
- `hostname` - 시스템 호스트명 관리
- `passwd` - 패스워드 및 사용자 계정 관리
- `login` - 사용자 로그인 시스템

### 6. 라이브러리 (40개)
#### 6.1 핵심 시스템 라이브러리
- `libc6` - GNU C 라이브러리
- `libc-bin` - GNU C 라이브러리 바이너리
- `libgcc-s1` - GCC 지원 라이브러리

#### 6.2 암호화 및 보안
- `libssl3t64` - OpenSSL 라이브러리
- `libgcrypt20` - 암호화 라이브러리
- `libgpg-error0` - GnuPG 오류 코드 라이브러리

#### 6.3 시스템 서비스
- `libsystemd0` - systemd 라이브러리
- `libudev1` - udev 라이브러리

#### 6.4 인증 및 접근 제어
- `libpam-modules` - 플러그형 인증 모듈
- `libpam-modules-bin` - PAM 모듈 바이너리
- `libpam-runtime` - PAM 런타임 지원
- `libpam0g` - 플러그형 인증 모듈 라이브러리

#### 6.5 SELinux 보안
- `libselinux1` - SELinux 런타임 라이브러리
- `libsemanage-common` - SELinux 정책 관리 공통 파일
- `libsemanage2` - SELinux 정책 관리 라이브러리
- `libsepol2` - SELinux 정책 라이브러리

#### 6.6 파일 시스템 및 압축
- `libblkid1` - 블록 장치 ID 라이브러리
- `libmount1` - 마운트 라이브러리
- `libuuid1` - UUID 생성 라이브러리
- `libacl1` - 접근 제어 목록 라이브러리
- `libattr1` - 확장 파일 속성 라이브러리
- `libbz2-1.0` - bzip2 압축 라이브러리
- `liblz4-1` - LZ4 압축 라이브러리
- `liblzma5` - XZ 압축 라이브러리
- `libzstd1` - Zstandard 압축 라이브러리
- `zlib1g` - zlib 압축 라이브러리

#### 6.7 터미널 및 텍스트 처리
- `libncursesw6` - ncurses 라이브러리 (wide character)
- `libtinfo6` - 터미널 정보 라이브러리
- `libpcre2-8-0` - Perl 호환 정규표현식 라이브러리

#### 6.8 기타 시스템 라이브러리
- `libaudit-common` - 감사 라이브러리 공통 파일
- `libaudit1` - 감사 라이브러리
- `libcap-ng0` - POSIX 기능 라이브러리 (차세대)
- `libcap2` - POSIX 기능 라이브러리
- `libcom-err2` - 공통 오류 설명 라이브러리
- `libcrypt1` - 암호화 라이브러리
- `libdebconfclient0` - debconf 클라이언트 라이브러리
- `libext2fs2t64` - ext2fs 라이브러리
- `libgmp10` - 임의 정밀도 산술 라이브러리
- `libmd0` - 메시지 다이제스트 라이브러리
- `libproc2-0` - 프로세스 정보 라이브러리
- `libsmartcols1` - 스마트 컬럼 출력 라이브러리
- `libss2` - 명령행 인터페이스 파싱 라이브러리

### 7. 시스템 초기화 및 관리 (4개)
- `init-system-helpers` - 시스템 초기화 헬퍼
- `sysvinit-utils` - System V init 유틸리티
- `sensible-utils` - 합리적인 대안 선택 유틸리티
- `logsave` - 로그 저장 유틸리티

### 8. 개발 및 스크립팅 도구 (4개)
- `gcc-14-base` - GCC 컴파일러 기본 패키지
- `perl-base` - Perl 인터프리터 (최소 설치)
- `mawk` - 패턴 스캐닝 및 데이터 추출 언어
- `hostname` - 시스템 식별자 설정

### 9. 터미널 지원 (2개)
- `ncurses-base` - 터미널 제어 기본 데이터
- `ncurses-bin` - 터미널 제어 바이너리

## 전체 설치된 패키지 목록 (알파벳 순)

| 번호 | 패키지명 | 설명 |
|------|----------|------|
| 1 | base-files | 시스템 기본 파일 |
| 2 | base-passwd | 기본 사용자/그룹 |
| 3 | bash | GNU Bourne Again Shell |
| 4 | bsdutils | BSD 유틸리티 |
| 5 | coreutils | GNU 핵심 유틸리티 |
| 6 | dash | POSIX 셸 |
| 7 | debconf | Debian 설정 관리 |
| 8 | debianutils | Debian 유틸리티 |
| 9 | diffutils | 파일 비교 도구 |
| 10 | dpkg | Debian 패키지 관리자 |
| 11 | e2fsprogs | ext2/3/4 파일시스템 도구 |
| 12 | findutils | 파일 검색 도구 |
| 13 | gcc-14-base | GCC 컴파일러 기본 |
| 14 | grep | 텍스트 검색 |
| 15 | gzip | 압축 도구 |
| 16 | hostname | 호스트명 관리 |
| 17 | init-system-helpers | 초기화 시스템 헬퍼 |
| 18 | libacl1 | ACL 라이브러리 |
| 19 | libattr1 | 확장 속성 라이브러리 |
| 20 | libaudit-common | 감사 라이브러리 공통 |
| 21 | libaudit1 | 감사 라이브러리 |
| 22 | libblkid1 | 블록 장치 ID 라이브러리 |
| 23 | libbz2-1.0 | bzip2 라이브러리 |
| 24 | libc-bin | GNU C 라이브러리 바이너리 |
| 25 | libc6 | GNU C 라이브러리 |
| 26 | libcap-ng0 | POSIX 기능 라이브러리 |
| 27 | libcap2 | POSIX 기능 라이브러리 |
| 28 | libcom-err2 | 공통 오류 라이브러리 |
| 29 | libcrypt1 | 암호화 라이브러리 |
| 30 | libdebconfclient0 | debconf 클라이언트 |
| 31 | libext2fs2t64 | ext2fs 라이브러리 |
| 32 | libgcc-s1 | GCC 지원 라이브러리 |
| 33 | libgcrypt20 | 암호화 라이브러리 |
| 34 | libgmp10 | 임의 정밀도 산술 |
| 35 | libgpg-error0 | GnuPG 오류 코드 |
| 36 | liblz4-1 | LZ4 압축 라이브러리 |
| 37 | liblzma5 | XZ 압축 라이브러리 |
| 38 | libmd0 | 메시지 다이제스트 |
| 39 | libmount1 | 마운트 라이브러리 |
| 40 | libncursesw6 | ncurses 라이브러리 |
| 41 | libpam-modules | PAM 모듈 |
| 42 | libpam-modules-bin | PAM 모듈 바이너리 |
| 43 | libpam-runtime | PAM 런타임 |
| 44 | libpam0g | PAM 라이브러리 |
| 45 | libpcre2-8-0 | Perl 정규식 라이브러리 |
| 46 | libproc2-0 | 프로세스 정보 라이브러리 |
| 47 | libselinux1 | SELinux 라이브러리 |
| 48 | libsemanage-common | SELinux 정책 관리 공통 |
| 49 | libsemanage2 | SELinux 정책 관리 |
| 50 | libsepol2 | SELinux 정책 라이브러리 |
| 51 | libsmartcols1 | 스마트 컬럼 출력 |
| 52 | libss2 | 명령행 파싱 라이브러리 |
| 53 | libssl3t64 | OpenSSL 라이브러리 |
| 54 | libsystemd0 | systemd 라이브러리 |
| 55 | libtinfo6 | 터미널 정보 라이브러리 |
| 56 | libudev1 | udev 라이브러리 |
| 57 | libuuid1 | UUID 라이브러리 |
| 58 | libzstd1 | Zstandard 압축 |
| 59 | login | 로그인 시스템 |
| 60 | logsave | 로그 저장 유틸리티 |
| 61 | mawk | AWK 구현 |
| 62 | mount | 마운트 유틸리티 |
| 63 | ncurses-base | ncurses 기본 데이터 |
| 64 | ncurses-bin | ncurses 바이너리 |
| 65 | passwd | 패스워드 관리 |
| 66 | perl-base | Perl 기본 패키지 |
| 67 | procps | 프로세스 유틸리티 |
| 68 | sed | 스트림 에디터 |
| 69 | sensible-utils | 합리적 대안 선택 |
| 70 | sysvinit-utils | SysV init 유틸리티 |
| 71 | tar | 아카이브 유틸리티 |
| 72 | util-linux | Linux 시스템 유틸리티 |
| 73 | zlib1g | zlib 압축 라이브러리 |

## 특징 및 용도

### 🎯 **설계 목적**
- **최소한의 기능적 시스템**: Ubuntu의 핵심 구성 요소만 포함
- **RISC-V 네이티브**: 모든 패키지가 RISC-V 64비트용으로 컴파일
- **빌드 환경 기반**: 패키지 컴파일을 위한 기본 도구 체인

### 🔧 **주요 기능**
- **패키지 관리**: dpkg, debconf를 통한 Debian 패키지 시스템
- **파일 시스템**: ext2/3/4 지원 및 기본 파일 연산
- **보안**: SELinux, PAM 기반 접근 제어
- **압축**: 다양한 압축 형식 지원 (gzip, bzip2, xz, lz4, zstd)
- **터미널**: ncurses 기반 터미널 인터페이스

### 🚀 **확장성**
이 기본 환경에서 추가 패키지 빌드 시 필요한 의존성들이 동적으로 설치됩니다:
- **개발 도구**: gcc, make, autotools 등
- **라이브러리**: 각 패키지의 특정 의존성
- **빌드 시스템**: cmake, meson 등

### 📊 **메모리 사용량**
- **설치 크기**: 약 200-300MB (압축 해제 후)
- **최소 RAM**: 512MB 권장
- **디스크 공간**: 1GB+ 여유 공간 필요 (빌드 과정 포함)

---

*생성일: 2025-08-23*  
*빌드 환경: Ubuntu 24.04 LTS (Noble) RISC-V64*  
*debootstrap 버전: 1.0.128ubuntu0.3*