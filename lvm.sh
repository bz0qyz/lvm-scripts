#!/bin/bash
set -e

#################
### VARIABLES ###
#################
# list:  all of the new physical disks (without /dev)
DEVS=(nvme1n1 nvme2n1)

# string: the name of the LVM volume group
VG_NAME=vg01

# string: the name of the LVM volume
LV_NAME=lv_localdata

# string: the size of the Logical Volume (see `man lvcreate` for options)
# -l = size in physical extents
# -L = size in bytes. Use m|g to denote megabytes or gigabytes
LV_SIZE="-l 100%FREE"

# string: mount path (without root /)
MOUNT_PATH=localdata

# string: Filesystem type
FS_TYPE=xfs

#############
### BEGIN ###
#############
# Create the partition table and partition
unset PARTS
for DEV in ${DEVS[@]}; do
	parted -s "/dev/${DEV}" mklabel gpt
	parted -a optimal /dev/${DEV} mkpart primary 2048s 100%
	parted -s "/dev/${DEV}" align-check optimal 1
	parted -s "/dev/${DEV}" set 1 lvm on
    [[ ${DEV} =~ [nvme] ]] && PART="p1" || PART="1"
	PARTS="${PARTS} /dev/${DEV}${PART}"
done

# Create the LVM Physical Volume(s)
pvcreate ${PARTS}

# Create the LVM Volume group
vgcreate ${VG_NAME} ${PARTS}

# Create the LVM volume
lvcreate -n ${LV_NAME} ${LV_SIZE} ${VG_NAME}

# Create the File System
mkfs.${FS_TYPE} /dev/${VG_NAME}/${LV_NAME}

# Get the systemd unit file name
UNITFILE=$(systemd-escape --suffix mount ${MOUNT_PATH})

# Create the systemd unit file and mount the disk
if [[ ! -e "/etc/systemd/system/${UNITFILE}" ]]; then
cat << EOF > "/etc/systemd/system/${UNITFILE}"
[Unit]
SourcePath=/etc/fstab
Description=${MOUNT_PATH} Volume
After=system.slice

[Mount]
What=/dev/${VG_NAME}/${LV_NAME}
Where=/${MOUNT_PATH}
Type=${FS_TYPE}
Options=defaults,noatime
EOF

  # Enable and start the systemd mount
  systemctl daemon-reload
  systemctl enable --now ${UNITFILE}

else
  echo "[ERROR] A systemd unit file for %{UNITFILE} already exists"
fi
