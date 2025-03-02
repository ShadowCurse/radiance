#!/bin/sh

SIZE=$1
in_container=$2

IMAGE=alpine
ROOTFS_FILE=$IMAGE.ext4
TMP_DIR=tmp_dir
CONTAINER_TMP_DIR=tmp_rootfs

if [[ $in_container == "true" ]]
then
  echo "[CONTAINER] installing packages"
  apk add openrc openssh util-linux agetty iperf3 fio
  rc-update add sshd

  echo "[CONTAINER] resetting root password"
  passwd -d root

  echo "[CONTAINER] moving id_rsa to authorized_keys"
  mkdir -p /root/.ssh
  mv /$CONTAINER_TMP_DIR/$IMAGE.id_rsa.pub /root/.ssh/authorized_keys

  echo "[CONTAINER] setting up host name"
  echo "alpine" > /etc/hostname

  echo "[CONTAINER] setting up network setup service"
  chmod +x /$CONTAINER_TMP_DIR/alpine_net.service
  chmod +x /$CONTAINER_TMP_DIR/net_setup.sh
  mv /$CONTAINER_TMP_DIR/alpine_net.service /etc/init.d/
  mv /$CONTAINER_TMP_DIR/net_setup.sh /usr/local/bin
  rc-update add alpine_net.service sysinit

  echo "[CONTAINER] setting up a login terminal on the serial console (ttyS0)"
  echo "ttyS0::respawn:/sbin/agetty --autologin root ttyS0 vt100" > /etc/inittab

  echo "[CONTAINER] making sure special file systems are mounted on boot"
  rc-update add devfs boot
  rc-update add procfs boot
  rc-update add sysfs boot

  echo "[CONTAINER] copying newly configured system to the rootfs image"
  for d in bin etc lib root sbin usr; do tar c "/$d" | tar x -C /$CONTAINER_TMP_DIR; done
  for dir in dev proc run sys var; do mkdir /$CONTAINER_TMP_DIR/${dir}; done

  echo "[CONTAINER] enabling sshd"
  mkdir /$CONTAINER_TMP_DIR/run/openrc
  touch /$CONTAINER_TMP_DIR/run/openrc/softlevel
  # Run this in uVM to setup network and ssh
  # rc-status
  # rc-service alpine_net.service restart

  exit
else
  echo "[HOST] creating rootfs file"
  dd if=/dev/zero of=$ROOTFS_FILE bs=1M count=$SIZE
  mkfs.ext4 -b 4K $ROOTFS_FILE

  echo "[HOST] creating ssh keys"
  ssh-keygen -f id_rsa -N ""
  mv id_rsa $IMAGE.id_rsa
  mv id_rsa.pub $IMAGE.id_rsa.pub

  echo "[HOST] creating tmp dir"
  mkdir -p $TMP_DIR
  sudo mount $ROOTFS_FILE $TMP_DIR
  cp ./mk_alpine.sh $TMP_DIR
  cp ./alpine_net.service $TMP_DIR
  cp ./net_setup.sh $TMP_DIR
  cp ./$IMAGE.id_rsa.pub $TMP_DIR

  echo "[HOST] running docker"
  sudo docker run --mount src="$(pwd)"/$TMP_DIR,target=/$CONTAINER_TMP_DIR,type=bind $IMAGE sh /$CONTAINER_TMP_DIR/mk_alpine.sh 0 true

  echo "[HOST] unmounting"
  sudo umount $TMP_DIR
  rm -r $TMP_DIR
fi
