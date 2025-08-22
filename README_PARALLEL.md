# Parallel RISC-V Package Build System

This system allows you to build RISC-V packages in parallel using separate isolated build environments.

## Files

- `build_single_package.sh` - Build a single package in isolation
- `build_parallel.sh` - Orchestrate multiple parallel builds
- `build_riscv_ubuntu.sh` - Original sequential build script

## Usage

### Single Package Build

```bash
# Basic usage (creates /srv/rvbuild-bash/)
sudo ./build_single_package.sh bash

# With custom base directory (creates /custom/rvbuild-bash/)
BUILD_BASE_DIR=/custom sudo ./build_single_package.sh bash

# With custom full path (overrides default naming)
sudo ./build_single_package.sh bash /srv/my-custom-build

# With environment variables
BUILD_PARALLEL=16 sudo ./build_single_package.sh coreutils
```

### Parallel Builds

```bash
# Build with 2 parallel jobs (creates /srv/rvbuild-*)
sudo ./build_parallel.sh 2

# Build with 4 parallel jobs (high-memory systems)
sudo ./build_parallel.sh 4

# Single job (sequential)
sudo ./build_parallel.sh 1

# Custom base directory (creates /custom/rvbuild-*)
BUILD_BASE_DIR=/custom sudo ./build_parallel.sh 2
```

### Manual Parallel Execution

```bash
# Start multiple builds manually
sudo ./build_single_package.sh bash /srv/build1 &
sudo ./build_single_package.sh coreutils /srv/build2 &
sudo ./build_single_package.sh grep /srv/build3 &

# Wait for completion
wait
```

## Directory Structure

Each build uses a separate `BUILD_ROOT_DIR`:

```
/srv/rvbuild-bash/              # Build directory for bash package
├── target-rootfs/              # Target installation root
├── builder-base/               # Clean builder environment
├── builder-base.tar            # Snapshot of builder-base
├── builder/                    # Active build environment
├── out/                        # Built .deb packages
│   └── bash/                   # Package-specific output
├── logs/                       # Build logs
└── records/                    # Build metadata

/srv/rvbuild-coreutils/         # Build directory for coreutils package
├── target-rootfs/              # Independent target root
├── ...
```

## Environment Variables

- `SUITE` - Ubuntu suite (default: noble)
- `ARCH` - Target architecture (default: riscv64)
- `MIRROR` - Ubuntu ports mirror
- `BUILD_PARALLEL` - Parallel jobs per package (default: nproc/4)

## Examples

### Example 1: Build bash and coreutils in parallel

```bash
# Terminal 1
sudo ./build_single_package.sh bash /srv/rvbuild-bash

# Terminal 2  
sudo ./build_single_package.sh coreutils /srv/rvbuild-coreutils
```

### Example 2: Automated parallel build

```bash
# Build all packages with 2 parallel jobs
sudo ./build_parallel.sh 2
```

### Example 3: Custom package list

Edit `build_parallel.sh` and modify the `PACKAGES` array:

```bash
PACKAGES=(
  bash grep sed tar
)
```

Then run:

```bash
sudo ./build_parallel.sh 2
```

## Output

Each package build creates:

1. **Built packages**: `$BUILD_ROOT_DIR/out/$PACKAGE/*.deb`
2. **Build logs**: `$BUILD_ROOT_DIR/logs/`
3. **Target system**: `$BUILD_ROOT_DIR/target-rootfs/`
4. **Build metadata**: `$BUILD_ROOT_DIR/records/`

## Monitoring

Monitor builds in real-time:

```bash
# Watch active build processes
watch 'ps aux | grep build_single_package'

# Monitor specific build log
tail -f /srv/rvbuild-bash/logs/20_build_bash.log

# Check build status
ls -la /srv/rvbuild-*/out/*/
```

## Troubleshooting

### Build Failures

Check individual build logs:
```bash
# Main build log
cat /srv/rvbuild-bash/logs/20_build_bash.log

# Configuration log (if configure fails)
cat /srv/rvbuild-bash/builder/bash-*/config.log
```

### Resource Issues

For high-memory usage, reduce parallel jobs:
```bash
# Use fewer parallel jobs
sudo ./build_parallel.sh 1

# Or reduce per-package parallelism
BUILD_PARALLEL=8 sudo ./build_single_package.sh bash
```

### Mount Issues

If mount cleanup fails:
```bash
# Manual cleanup
sudo umount /srv/rvbuild-*/builder/{dev/pts,dev,sys,proc} 2>/dev/null || true
```

## Performance Considerations

- **Memory**: Each build uses ~2-4GB RAM
- **Storage**: Each build needs ~10-20GB space
- **CPU**: Optimal parallel jobs = total cores / 4
- **QEMU overhead**: Each emulated process adds ~10x CPU usage

## Security

- All builds run in isolated chroot environments
- No shared state between parallel builds
- Mount points are properly cleaned up
- Build directories are separated by PID/job ID

## Integration

To integrate with existing systems:

```bash
# Build specific packages
for pkg in bash coreutils grep; do
  sudo ./build_single_package.sh "$pkg" "/srv/rvbuild-$pkg" &
done
wait

# Collect all outputs
mkdir -p /srv/final-output
cp /srv/rvbuild-*/out/*/*.deb /srv/final-output/
```