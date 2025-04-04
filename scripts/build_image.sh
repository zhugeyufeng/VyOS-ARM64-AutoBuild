#!/bin/bash
set -e

# 检查是否以root权限运行
if [ "$(id -u)" -ne 0 ]; then
   echo "此脚本需要root权限运行" >&2
   exit 1
fi

# 检查参数
if [ -z "$1" ] || [ ! -f "$1" ]; then
    echo "错误: 请提供有效的squashfs文件作为参数" >&2
    echo "用法: $0 path/to/vyos-squashfs-file.squashfs" >&2
    exit 1
fi

SQUASHFS="$1"
IMG=vyos-arm64.img
QCOW2=vyos-arm64.qcow2
MOUNT_ROOT=$(mktemp -d)
MOUNT_EFI=$(mktemp -d)

# 清理函数
cleanup() {
    echo "执行清理..."
    # 尝试卸载所有挂载点
    umount -lf ${MOUNT_ROOT}/boot/efi ${MOUNT_ROOT}/{dev,proc,sys} ${MOUNT_ROOT} 2>/dev/null || true
    umount ${MOUNT_EFI} 2>/dev/null || true
    # 清理循环设备
    losetup -D || true
    # 删除临时目录
    rm -rf ${MOUNT_ROOT} ${MOUNT_EFI}
    echo "清理完成"
}

# 设置出错或脚本终止时的清理
trap cleanup EXIT INT TERM

echo "创建40GB磁盘镜像..."
dd if=/dev/zero of=$IMG bs=1M count=40960
loopdev=$(losetup --find --show $IMG)

echo "分区磁盘为EFI + root..."
parted -s $loopdev mklabel gpt
parted -s $loopdev mkpart ESP fat32 1MiB 100MiB
parted -s $loopdev set 1 boot on
parted -s $loopdev mkpart root ext4 100MiB 100%

echo "重新加载循环设备以识别分区..."
losetup -d $loopdev
loopdev=$(losetup --find --partscan --show $IMG)

echo "格式化分区..."
mkfs.vfat ${loopdev}p1
mkfs.ext4 ${loopdev}p2

echo "挂载分区..."
mount ${loopdev}p2 ${MOUNT_ROOT}
mount ${loopdev}p1 ${MOUNT_EFI}

echo "提取rootfs到挂载点..."
unsquashfs -f -d ${MOUNT_ROOT} "$SQUASHFS"

echo "设置EFI分区..."
mkdir -p ${MOUNT_ROOT}/boot/efi
mount --bind ${MOUNT_EFI} ${MOUNT_ROOT}/boot/efi

echo "挂载系统目录准备chroot..."
mount --bind /dev ${MOUNT_ROOT}/dev
mount --bind /proc ${MOUNT_ROOT}/proc
mount --bind /sys ${MOUNT_ROOT}/sys

echo "创建存储目录..."
mkdir -p ${MOUNT_ROOT}/mnt/storage

echo "安装GRUB EFI引导加载程序..."
chroot ${MOUNT_ROOT} /bin/bash <<'EOF'
grub-install --target=arm64-efi --efi-directory=/boot/efi --bootloader-id=vyos --recheck --no-floppy
update-grub
EOF

echo "卸载所有挂载点..."
umount -lf ${MOUNT_ROOT}/boot/efi ${MOUNT_ROOT}/{dev,proc,sys} ${MOUNT_ROOT}
umount ${MOUNT_EFI}
losetup -d $loopdev

echo "转换镜像为qcow2格式..."
qemu-img convert -f raw -O qcow2 $IMG $QCOW2

echo "构建完成: $IMG 和 $QCOW2"

name: Build VyOS ARM64 Image

on:
  workflow_dispatch:
    inputs:
      release_name:
        description: '发布版本名称(可选)'
        required: false
        default: 'VyOS ARM64 自动构建'

jobs:
  build:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Checkout vyos-build
        uses: actions/checkout@v4
        with:
          repository: vyos/vyos-build
          ref: current
          path: vyos-build

      - name: Setup Docker
        uses: docker/setup-buildx-action@v2

      - name: Configure Docker permissions
        run: |
          sudo usermod -aG docker $USER
          # 确保Docker可以正常工作
          docker info

      - name: Install build dependencies
        run: |
          # 更新包索引
          sudo apt-get update
          
          # 安装系统工具和VyOS构建依赖
          sudo apt-get install -y qemu-utils parted xz-utils dosfstools squashfs-tools git \
            python3-cracklib build-essential debhelper libpam-dev libnss3-dev uuid-dev \
            libssl-dev grub2-common e2fsprogs debootstrap \
            live-build pbuilder devscripts
          
          # 尝试安装grub-efi-arm64-bin (如果可用)
          sudo apt-get install -y grub-efi-arm64-bin || echo "grub-efi-arm64-bin not available"
          
          # 安装Python依赖
          sudo pip3 install tomli jinja2 gitpython pystache python-git
          
          # 如果未通过pip安装python-cracklib，使用系统包
          if ! python3 -c "import cracklib" 2>/dev/null; then
            echo "尝试使用apt安装cracklib..."
            sudo apt-get install -y python3-cracklib
          fi
          
          # 安装其他Python模块
          sudo apt-get install -y python3-pystache python3-git || echo "尝试通过pip安装..."
          
          # 验证工具已安装
          echo "检查必要工具是否已安装:"
          for tool in docker qemu-img parted xz mkfs.vfat mksquashfs git lb pbuilder; do
            if command -v $tool >/dev/null 2>&1; then
              echo "$tool: 已安装"
            else
              echo "$tool: 未安装"
            fi
          done
          
          # 验证Python模块已安装
          echo "检查必要Python模块是否已安装:"
          for module in tomli jinja2 git cracklib pystache; do
            if python3 -c "import $module" 2>/dev/null; then
              echo "$module: 已安装"
            else
              echo "$module: 未安装"
              exit 1
            fi
          done

      - name: Fix Python path for cracklib
        run: |
          # 查找cracklib模块位置
          CRACKLIB_PATH=$(find /usr/lib/ -name "cracklib.*.so" 2>/dev/null)
          if [ ! -z "$CRACKLIB_PATH" ]; then
            CRACKLIB_DIR=$(dirname "$CRACKLIB_PATH")
            echo "Found cracklib at: $CRACKLIB_DIR"
            export PYTHONPATH=$PYTHONPATH:$CRACKLIB_DIR
          fi

      - name: Build ARM64 squashfs (in Docker)
        run: |
          cd vyos-build
          # 设置Python路径
          export PYTHONPATH=$PYTHONPATH:$(pwd):$(pwd)/build/vyos-1x/python
          sudo -E make docker-arm64
          sudo ./configure --architecture arm64
          sudo make image

      - name: Generate version tag
        id: version
        run: echo "tag=vyos-arm64-$(date +'%Y%m%d')" >> $GITHUB_OUTPUT

      - name: Package to bootable disk image
        run: |
          # 确保构建脚本存在
          if [ ! -f ./scripts/build_image.sh ]; then
            echo "构建脚本不存在，正在检查目录结构..."
            find . -name "build_image.sh" -type f
            exit 1
          fi
          
          chmod +x ./scripts/build_image.sh
          sudo ./scripts/build_image.sh ./vyos-build/build/*/vyos-*.squashfs
