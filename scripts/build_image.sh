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
