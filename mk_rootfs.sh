#!/bin/bash

SIZE=$1
in_container=$2

ROOTFS_FILE=rootfs.ext4
TMP_DIR=./tmp_dir

if [[ $in_container == "true" ]]
then
  echo "[CONTAINER] installing packages"
  apk add openrc
  apk add util-linux

  echo "[CONTAINER] removing root password"
  passwd -d root

  echo "[CONTAINER] setting up a login terminal on the serial console (ttyS0)"
  ln -s agetty /etc/init.d/agetty.ttyS0
  echo ttyS0 > /etc/securetty
  rc-update add agetty.ttyS0 default

  echo "[CONTAINER] making sure special file systems are mounted on boot"
  rc-update add devfs boot
  rc-update add procfs boot
  rc-update add sysfs boot

  echo "[CONTAINER] copying newly configured system to the rootfs image"
  for d in bin etc lib root sbin usr; do tar c "/$d" | tar x -C /tmp_rootfs; done
  for dir in dev proc run sys var; do mkdir /tmp_rootfs/${dir}; done

  exit
else
  echo "[HOST] creating rootfs file"
  dd if=/dev/zero of=$ROOTFS_FILE bs=1M count=$SIZE
  mkfs.ext4 $ROOTFS_FILE

  echo "[HOST] creating tmp dir"
  mkdir -p $TMP_DIR
  sudo mount $ROOTFS_FILE $TMP_DIR
  cp ./mk_rootfs.sh $TMP_DIR

  echo "[HOST] running docker"
  sudo docker run -it --rm -v $TMP_DIR:/tmp_rootfs alpine sh tmp_rootfs/mk_rootfs.sh 0 true

  echo "[HOST] unmounting"
  sudo umount $TMP_DIR
  rm -r $TMP_DIR
fi
