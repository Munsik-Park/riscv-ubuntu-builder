riscv-minimal-build/
├─ seeds/                  # 최소 seed 정의 (우리가 관리)
│  ├─ minimal.seed
│  └─ germinate.cfg
├─ repo/                   # aptly 스냅샷/퍼블리시 (우리 APT 레포)
├─ scripts/
│  ├─ 00_prereqs_host.sh
│  ├─ 10_aptly_mirror_freeze.sh
│  ├─ 20_germinate_expand.sh
│  ├─ 30_buildgraph_toposort.sh
│  ├─ 40_make_sbuild_chroot_native.sh
│  ├─ 50_build_queue.sh
│  ├─ 60_publish_testing_stable.sh
│  └─ 70_make_image_mmdebstrap.sh
├─ out/
│  ├─ expanded-binaries.txt
│  ├─ source-list.txt
│  ├─ build-order.txt
│  └─ images/ubuntu-riscv64-minimal.qcow2
└─ configs/
   ├─ sbuildrc
   ├─ apt-pinning.conf
   └─ mmdebstrap.sources.list
