#!/bin/bash

SIZE=$1
in_container=$2

IMAGE=ubuntu
ROOTFS_FILE=$IMAGE.ext4
TMP_DIR=tmp_dir
CONTAINER_TMP_DIR=tmp_rootfs

if [[ $in_container == "true" ]]
then
  echo "[CONTAINER] installing packages"
  export DEBIAN_FRONTEND=noninteractive
  apt update
  apt install -y --no-install-recommends udev systemd-sysv iproute2 openssh-server iputils-ping iperf3 fio
  apt autoremove

  echo "[CONTAINER] resetting root password"
  passwd -d root

  echo "[CONTAINER] moving id_rsa to authorized_keys"
  mv /$CONTAINER_TMP_DIR/$IMAGE.id_rsa.pub /root/.ssh/authorized_keys

  echo "[CONTAINER] setting up host name"
  echo "ubuntu" > /etc/hostname

  echo "[CONTAINER] setting up network setup service"
  mv /$CONTAINER_TMP_DIR/ubuntu_net.service /etc/systemd/system
  mv /$CONTAINER_TMP_DIR/net_setup.sh /usr/local/bin
  ln -s /etc/systemd/system/ubuntu_net.service /etc/systemd/system/sysinit.target.wants/ubuntu_net.service

  echo "[CONTAINER] setting up autologin"
  for console in ttyS0; do
    mkdir "/etc/systemd/system/serial-getty@$console.service.d/"
    cat <<'EOF' > "/etc/systemd/system/serial-getty@$console.service.d/override.conf"
[Service]
# systemd requires this empty ExecStart line to override
ExecStart=
ExecStart=-/sbin/agetty --autologin root -o '-p -- \\u' --keep-baud 115200,38400,9600 %I dumb
EOF
done

  echo "[CONTAINER] disable useless services"
  rm -f /etc/systemd/system/multi-user.target.wants/systemd-resolved.service
  rm -f /etc/systemd/system/dbus-org.freedesktop.resolve1.service
  rm -f /etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service

  echo "[CONTAINER] delete useless files"
  rm -rf /usr/share/{doc,man,info,locale}

  echo "[CONTAINER] copying newly configured system to the rootfs image"
  for d in bin etc lib root sbin usr; do tar c "/$d" | tar x -C /$CONTAINER_TMP_DIR; done
  for dir in dev proc run sys var; do mkdir /$CONTAINER_TMP_DIR/${dir}; done

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
  cp ./mk_ubuntu.sh $TMP_DIR
  cp ./ubuntu_net.service $TMP_DIR
  cp ./net_setup.sh $TMP_DIR
  cp ./$IMAGE.id_rsa.pub $TMP_DIR

  echo "[HOST] running docker"
  sudo docker run --mount src="$(pwd)"/$TMP_DIR,target=/$CONTAINER_TMP_DIR,type=bind $IMAGE bash /$CONTAINER_TMP_DIR/mk_ubuntu.sh 0 true

  echo "[HOST] unmounting"
  sudo umount $TMP_DIR
  rm -r $TMP_DIR
fi
