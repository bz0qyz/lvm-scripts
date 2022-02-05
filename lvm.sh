#!/bin/bash
set -e

#################
### DEFAULTS ###
#################
# string: the name of the LVM volume group
VG_NAME=vg01
# string: the name of the LVM volume
LV_NAME=lv01
# string: the size of the Logical Volume (see `man lvcreate` for options)
LV_SIZE="-l 100%FREE"
# string: mount path
MOUNT_PATH=/data
# string: Filesystem type
FS_TYPE=xfs
# Boolean: Run as a batch job with no user input. (answer yes to all prompts)
BATCH=0
# Boolean: Run in reverse and undo all the operations (use with caution)
ROLLBACK=0
# Boolean: Run in safe mode. This will protect data on the block devices
SAFE_MODE=0

## Colored Output Variables
NC='\033[0m' # No Color
RED='\033[0;31m'
GRN='\033[0;32m'
BRN='\033[0;33m'
GRY='\033[0;37m'
YLW='\033[1;33m'

SCRIPT_NAME="LVM Dope"
SCRIPT_VERSION=1.0.0

#declare -A FS_GROW
#FS_GROW=([xfs]="xfs_growfs" [ext3]="resize2fs" [ext4]="resize2fs" [btrfs]="btrfs filesystem resize")
declare -A DEVPARTS_EXIST
declare -A PVS_EXIST
FS_ALLOWED="ext2 ext3 ext4 xfs btrfs"
STR_BOOL=("False" "True")
VG_EXIST=0
LV_EXIST=0
FS_MOUNTED=0
UNITFILE=""
UNITFILE_EXISTS=1

#################
### FUNCTIONS ###
#################
function show_help() {
	echo -e "\n${BRN}*********** ${SCRIPT_NAME} v.${SCRIPT_VERSION} ***********${NC}"
	echo -e "${GRY}Usage ${0} -v <volume group name> -l <logical volume name> -s <logical volume size> [-m <mount path>]\n"
	echo "-b|--batch - Run in batch mode with no user input. Answers YES to all questions."
	echo "-g|--vg-name - The name of the volume group to create or append to. Default: ${VG_NAME}"
	echo "-l|--lv-name - The name of the logical volume to create. Default: ${LV_NAME}"
	echo "-s|--lv-size - The size of the logical volume. Default: 100%. Use size integer followed by m|g. Default: ${LV_SIZE}"
	echo "-m|--mount-path - The location on the root file system to mount the new volume group. Default: ${MOUNT_PATH}"
	echo "-f|--fs-type - The name of the logical volume to create. Options: ${FS_ALLOWED}."
	echo "-r|--rollback - Rollback an LVM deployment. WARNING: This will remove all LVM parts and erase the block storage devices."
	echo "--safe|--safe-mode - Do not wipe partition tables from block devices."
	echo -e "\nEXAMPLE: ${0} -g ${VG_NAME} -d ${LV_NAME} -s 200g -m ${MOUNT_PATH} /dev/sdb /dev/sdc ${NC}"
}

function log(){
	## Needs named arguments with the option of success/fail appended
	[[ -z ${2} ]] || [[ ${2} -eq 0 ]] && PRE="${GRN}[INFO]"
	[[ -n ${2} ]] && [[ ${2} -eq 1 ]] && PRE="${YLW}[WARNING]"
	[[ -n ${2} ]] && [[ ${2} -gt 1 ]] && PRE="${RED}[ERROR]"
	echo -e "${PRE} ${1}${NC}"
	if [[ -n ${2} ]] && [[ ${2} -gt 1 ]]; then
		[[ -n ${3} ]] && show_help
		exit ${2}
	fi
}

##################
### VALIDATION ###
##################
function validate_script() {
	FATAL=0
	# Verify that we are running as root
	[[ $(id -u) -gt 0 ]] && FATAL=1 && log "This script MUST be run as root. You are: $(id -un)" 2
	# Verify that LVM is installed
	which lvm > /dev/null 2>&1
	[[ ${?} -gt 0 ]] && FATAL=1 && log "LVM is not installed" 2 1
	# Verify that parted is installed
	which parted > /dev/null 2>&1
	[[ ${?} -gt 0 ]] && FATAL=1 && log "parted is not installed" 2 1
	# Exit script on fatal error
	[[ ${FATAL} -eq 1 ]] && exit 1 || return 0
}

function validate_args() {
	FATAL=0
	# Validate the LV_SIZE
	[[ ! "${LV_SIZE}" =~ [0-1]*[m|g|%FREE] ]] && FATAL=1 && log "Invald input for --lv-size: ${LV_SIZE}" 2 1
	# Validate the MOUNT_PATH
	[[ ! "${MOUNT_PATH}" =~ ^/.* ]] && FATAL=1 && log "Invald input for --mount-path: ${MOUNT_PATH}" 2 1
	# Validate the FS_TYPE
	[[ ! $(echo ${FS_ALLOWED} | grep -w "${FS_TYPE}") ]] && FATAL=1 && log "Invald input for --fs-type. Allowed options: ${FS_ALLOWED}" 2 1
	# Validate the block devices (DEVS)
	## Validate that we have block devices in arguments
	[[ ! ${#DEVS} -gt 0 ]] && FATAL=1 && log "No raw storage devices were provided. Unable to proceed." 2 1
	for DEV in "${DEVS[@]}"; do
		## Validate that the device is a full path
		[[ ! "${DEV}" =~ ^\/dev\/.* ]] && FATAL=1 && log "Device: ${DEV} does not look like a valid block device." 2 1
		## Validate that the device exists
		[[ ! -b "${DEV}" ]] && FATAL=1 && log "Block device: ${DEV} does not exist." 2
	done

	if [[ ${FATAL} -eq 1 ]]; then
		echo -en "\n"
		show_help
	fi
}

function validate_job() {
	set +e
  # Validate that device and PV exist
	for DEV in "${DEVS[@]}"; do
		[[ "${DEV}" =~ /dev/[nvme] ]] && PART="p1" || PART="1"
		## Validate the device exists
		if [[ -b "/dev/${DEV}${PART}" ]]; then
			DEVPARTS_EXIST[${DEV}${PART}]=1
		else
			DEVPARTS_EXIST[${DEV}${PART}]=0
		fi

		pvdisplay "${DEV}${PART}" >/dev/null 2>&1
		PVS_EXIST["${DEV}${PART}"]=${?}

	done

	# Validate if the VG exists
	if vgdisplay ${VG_NAME} > /dev/null 2>&1 ;then
		VG_EXIST=1
		[[ ${ROLLBACK} -eq 0 ]] && log "LVM Volume Group: ${VG_NAME} already exists." 1
	else
		VG_EXIST=0
		[[ ${ROLLBACK} -gt 0 ]] && log "LVM Volume: ${LV_NAME} does not exist." 1
	fi

	# Validate if the LV exists
	if lvdisplay "/dev/${VG_NAME}/${LV_NAME}" > /dev/null 2>&1 ;then
		LV_EXIST=1
		[[ ${ROLLBACK} -eq 0 ]] && log "LVM Volume: ${LV_NAME} already exists." 1
	else
		LV_EXIST=0
		[[ ${ROLLBACK} -gt 0 ]] && log "LVM Volume: ${LV_NAME} does not exist." 1
	fi

	# Validate the LV is mounted
  if [[ $(mount | grep -ce "on ${MOUNT_PATH} ") -gt 0 ]]; then
		FS_MOUNTED=1
		[[ ${ROLLBACK} -eq 0 ]] && log "${MOUNT_PATH} is in use (mounted)" 1
	else
		FS_MOUNTED=0
		[[ ${ROLLBACK} -gt 0 ]] && log "${MOUNT_PATH} is not mounted" 1
	fi
	# Get the systemd unit file name
	UNITFILE=$(systemd-escape --suffix mount ${MOUNT_PATH:1})
	if [[ -e "/etc/systemd/system/${UNITFILE}" ]]; then
		UNITFILE_EXISTS=1
		[[ ${ROLLBACK} -eq 0 ]] && log "A systemd unit file for: ${MOUNT_PATH} already exists" 1
	else
		UNITFILE_EXISTS=0
		[[ ${ROLLBACK} -gt 0 ]] && log "A systemd unit file for: ${MOUNT_PATH} does not exist" 1
	fi

	set -e
	return 0
}

######################
### WORK FUNCTIONS ###
#####################
function delpart() {
	# $1 = device path (eg: /dev/sda)
	if [[ ${BATCH} -eq 1 ]]; then
		DO_WIPE="y"
	else
		echo -en "\n${YLW}Wipe the device partition table? (y|n)${NC}"
		read -p ":" DO_WIPE
	fi
	if [[ "${DO_WIPE}" =~ [y|Y] ]]; then
		log "Wiping the partition table on device: ${DEV}"
		parted "${DEV}" rm 1 >/dev/null
		dd if="/dev/zero" of="${DEV}" bs=10240 count=4 > /dev/null 2>&1
		return ${?}
	else
		log "Unable to proceed while there are partitions on ${DEV}" 2
		return 1
	fi
}

function makeparts() {
	# $1 = device path (eg: /dev/sda)
	DEV=${1}
	[[ "${DEV}" =~ /dev/[nvme] ]] && PART="p1" || PART="1"

	# Verify that there are no partitions on the block device
	if [[ $(cat "/proc/partitions" | grep -c "${DEV:5}") -gt 1 ]] && [[ ${SAFE_MODE} -eq 0 ]]; then
		log "Device: ${DEV} has already been partitioned." 1
		delpart "${DEV}"
	fi
	if [[ ${SAFE_MODE} -eq 0 ]]; then
		log "Partitioning device: ${DEV}"
		parted -s "${DEV}" mklabel gpt && \
		parted -a optimal "${DEV}" mkpart primary 2048s 100% && \
		parted -s "${DEV}" align-check optimal 1 && \
		parted -s "${DEV}" set 1 lvm on
  fi

	PARTS="${PARTS} ${DEV}${PART}"
	return 0
}

function umount_filesystem() {
	log "Un-mounting: ${MOUNT_PATH}"
	if [[ ${UNITFILE_EXISTS} -eq 1 ]]; then
		if systemctl disable --now ${UNITFILE} ; then
			### Remove Unit file
			rm -f "/etc/systemd/system/${UNITFILE}" && \
			systemctl daemon-reload
		fi
	else
		umount "${MOUNT_PATH}" > /dev/null
		log "File system umounted without systemd. You may need to remove an entry in /etc/fstab" 1
	fi
}

function mountfilesystem() {
	# Create the systemd unit file and mount the disk
	if [[ ${UNITFILE_EXISTS} -eq 0 ]]; then
		log "Mounting /dev/${VG_NAME}/${LV_NAME} at ${MOUNT_PATH}"
		cat <<- EOF > "/etc/systemd/system/${UNITFILE}"
		[Unit]
		Description=${MOUNT_PATH} Volume
		After=system.slice

		[Mount]
		What=/dev/${VG_NAME}/${LV_NAME}
		Where=${MOUNT_PATH}
		Type=${FS_TYPE}
		Options=defaults,noatime

		[Install]
		WantedBy=multi-user.target
		EOF
	  # Enable and start the systemd mount
	  systemctl daemon-reload
	  systemctl enable --now ${UNITFILE}
	fi
}

function do_forward() {
	# Standard process steps
	if [[ ${VG_EXIST} -eq 0 ]]; then
		for DEV in "${DEVS[@]}"; do
			makeparts "${DEV}"
		done
		## Create the LVM Physical Volume(s)
		pvcreate ${PARTS[*]}
		log "Created LVM Physical Volumes: ${PARTS[*]}"
		## Create the LVM Volume group
		log "Creating LVM Volume Group: ${VG_NAME}"
		vgcreate "${VG_NAME}" ${PARTS}

  fi
	## Create the LVM volume
	if [[ ${LV_EXIST} -eq 0 ]]; then
		log "Creating LVM Logical Volume: ${LV_NAME}"
		lvcreate -y -n "${LV_NAME}" ${LV_SIZE} "${VG_NAME}"
	fi
	## Create the File System
	if [[ ${FS_MOUNTED} -eq 0 ]] && [[ ${SAFE_MODE} -eq 0 ]]; then
		set +e
		log "Creating ${FS_TYPE} File System."
		[[ ${FS_TYPE} =~ ext ]] && FORCE="-F" || FORCE="-f"
		[[ ${SAFE_MODE} -gt 0 ]] || [[ ${BATCH} -gt 1 ]] && FORCE=""
		mkfs.${FS_TYPE} ${FORCE} -L "${VG_NAME}_$(basename ${MOUNT_PATH}|tr '[:lower:]' '[:upper:]')" "/dev/${VG_NAME}/${LV_NAME}" >/dev/null
		[[ ${?} -gt 0 ]] && set -e && return 1
		set -e
  fi
	## mount the filesystem
	if [[ ${UNITFILE_EXISTS} -eq 0 ]] && [[ ${FS_MOUNTED} -eq 0 ]]; then
		mountfilesystem
	else
		log "Failed to mount the filesystem at ${MOUNT_PATH}. A systemd unit file already exists or it's already mounted." 2
	fi
}

function do_reverse() {
	# rollback process steps
	## Unmount filesystem
	if [[ ${FS_MOUNTED} -eq 1 ]] || [[ ${UNITFILE_EXISTS} -eq 1 ]]; then
		umount_filesystem
  fi
	## Remove the Logical Volume
	if [[ ${LV_EXIST} -eq 1 ]]; then
		log "Removing Logical Volume: ${LV_NAME}"
		lvremove --force "/dev/${VG_NAME}/${LV_NAME}"
  fi
	## Remove the Volume Group
	if [[ ${VG_EXIST} -eq 1 ]]; then
		log "Removing Volume Group: ${VG_NAME}"
		### Remove all physical volumes from the Volume Group
		set +e && vgreduce --all "${VG_NAME}" >/dev/null 2>&1 && set -e
		vgremove --force "${VG_NAME}"
	fi
	## Wipe partition table from the block devices
	for DEV in "${DEVS[@]}"; do
		[[ "${DEV}" =~ /dev/[nvme] ]] && PART="p1" || PART="1"
		### Remove LVM the physical volume
		if [[ ${PVS_EXIST["${DEV}${PART}"]} -eq 0 ]]; then
			log "Removing LVM Physical Volume: ${DEV}${PART}"
			pvremove "${DEV}${PART}"
	  else
			log "Physical Volume: ${DEV}${PART} does not exist." 1
	  fi
		### Wipe the partiton table
		if [[ ${DEVPARTS_EXIST[${DEV}${PART}]} -eq 0 ]]; then
			if [[ ${SAFE_MODE} -eq 0 ]]; then
				log "Wiping partitions from: ${DEV}"
				delpart "${DEV}"
			fi
		fi
	done
}

# Validate that dependencies are met
validate_script

############################
# Process passed arguments #
############################
DEVS=()
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    -g|--vg-name)
      VG_NAME="${2}"
      shift # past argument
      shift # past value
      ;;
		-l|--lv-name)
      LV_NAME="${2}"
      shift # past argument
      shift # past value
      ;;
		-s|--lv-size)
      LV_SIZE="-L ${2}"
      shift # past argument
      shift # past value
      ;;
		-f|--fs-type)
      FS_TYPE="${2}"
      shift # past argument
      shift # past value
      ;;
		-m|--mount-path)
      MOUNT_PATH="${2}"
      shift # past argument
      shift # past value
      ;;
		-h|--help)
			show_help
			exit 0
			;;
		-b|--batch)
			BATCH=1
			shift # past argument
			;;
		-r|--rollback)
			ROLLBACK=1
			shift # past argument
			;;
		--safe|--safe-mode)
			SAFE_MODE=1
			shift # past argument
			;;
		*)    # device name
			DEVS+=("$1") # save it in an array for later
			shift # past argument
			;;
	esac
done

validate_args

if [[ ${BATCH} -eq 0 ]]; then
	[[ ${ROLLBACK} -eq 0 ]] && VERBS=("Create" "Partition" "Mount") || VERBS=("Delete" "Wipe" "Dismount")
	echo -e "${GRY}############[ JOB SUMMARY ]############${NC}"
	echo -e "${VERBS[1]} Block Devices: ${YLW}${DEVS[*]}${NC}"
	echo -e "${VERBS[0]} Volume Group named: ${YLW}${VG_NAME}${NC}"
	echo -e "${VERBS[0]} Logical Volume named: ${YLW}${LV_NAME}${NC}"
	if [[ ${ROLLBACK} -eq 0 ]]; then
	  echo -e " - Size: ${YLW}${LV_SIZE}${NC}"
	  echo -e " - File system type: ${YLW}${FS_TYPE}${NC}"
  fi
	echo -e "${VERBS[2]} the Logical Volume at: ${YLW}${MOUNT_PATH}${NC}"
	echo -e "\nSafe Mode: ${STR_BOOL[${SAFE_MODE}]}"
	echo -e "${GRY}#######################################${NC}"
	echo -en "\n${YLW}Proceed? (y|n)${NC}"
	read -p ":" DO_JOB
else
	DO_JOB="y"
fi

#############
### BEGIN ###
#############
if [[ ${DO_JOB} =~ [y|Y] ]]; then
	if [[ ${ROLLBACK} -eq 0 ]]; then
		validate_job && do_forward
	else
		validate_job && do_reverse
	fi
else
	exit 1
fi
exit 0
