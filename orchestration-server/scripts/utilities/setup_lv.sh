#!/bin/bash

set -eu

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

volume_name="ubuntu-vg"
size=""
name=""

function usage_reminder()
{
	local item_invalid=$1 given_item=$2
	echo "Variable $item_invalid is incorrect, value given: $given_item" >&2
	echo "Usage: $0 -s <size> -n <name> -v <volume_name|optional>" >&2
	exit 1
}


while getopts ":s:n:v:" opt; do
	case "$opt" in
		s) size="$OPTARG" ;;
		n) name="$OPTARG" ;;
		v) volume_name="$OPTARG" ;;
		\?) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
		:) echo "Option -$OPTARG requires an argument." >&2; exit 1 ;;
	esac
done

shift $((OPTIND-1))

if [[ $# -gt 0 ]]; then
	usage_reminder "extra items given" "$*"
fi

if [[ -z "$size" ]]; then
	echo "Size variable is missing" >&2
	exit 1
fi

if [[ -z "$name" ]]; then
	echo "Name variable is missing" >&2
	exit 1
fi



if [[ ! $name =~ ^[a-z][a-z0-9_-]{0,15}$ ]]; then
	usage_reminder "name" "$name"
fi

if [[ ! $volume_name =~ ^[a-z][a-z0-9_.+-]*$ ]]; then
	usage_reminder "volume_name" "$volume_name"
fi


function run_lv_create_cmd()
{
	local size=$1 name=$2 volume_name=$3 size_number mult requested available

	if [[ ! $size =~ ^([0-9]{1,6})([MGT])$ ]]; then
  		usage_reminder "size" "$size"
	fi

	size_number=${BASH_REMATCH[1]}

	case ${BASH_REMATCH[2]} in
  	M) mult=$(( 1024**2 )) ;;
  	G) mult=$(( 1024**3 )) ;;
  	T) mult=$(( 1024**4 )) ;;
	esac

	requested=$(( 10#$size_number * mult ))

	available=$(vgs --noheadings --nosuffix --units b -o vg_free "$volume_name" | tr -d '[:space:]')

	if [[ -z $available ]]; then
		echo "Available var came back empty, check if $volume_name name in vgs command is valid" >&2
		echo "Command used //vgs --noheadings --nosuffix --units b -o vg_free $volume_name | tr -d '[:space:]'//" >&2
		return 1
	fi

	if [[ $requested -gt $available ]]; then
		echo "There isn't enough space to complete the lv create command as set" >&2
		echo "Amount requested: $requested${BASH_REMATCH[2]} vs. amount available: $available${BASH_REMATCH[2]}" >&2
		return 1
	else
		if lvcreate -L "$size" -n "$name" "$volume_name"; then
			echo "Named LV ($name) created with requested size: $size"
			return 0
		else
			echo "LV creation failed" >&2
			return 1
		fi
	fi
}

function run_mkfs_cmd_for_ext4_type()
{
	local name=$1 volume_name=$2

	local device="/dev/$volume_name/$name" existing_type

	if existing_type=$(blkid -p -o value -s TYPE "$device"); then
		echo "Refused to format $device, since it already contains a $existing_type filesystem" >&2
		return 1
	fi

	if mkfs.ext4 -L "$name" "$device"; then
		echo "The named lv $name was converted to ext4 type"
		return 0
	else
		echo "Failed to convert named lv $name to ext4 type" >&2
		return 1
	fi


}

function run_tune2fs_cmd()
{
	local name=$1
	local volume_name=$2

	if tune2fs -m 1 "/dev/$volume_name/$name"; then
		echo "The named lv $name was tuned to the filesystem"
		return 0
	else
		echo "The named lv $name was not tuned to the filesystem" >&2
		return 1
	fi

}


function main()
{

	run_lv_create_cmd "$size" "$name" "$volume_name" || return 1
	run_mkfs_cmd_for_ext4_type "$name" "$volume_name" || return 1
	run_tune2fs_cmd "$name" "$volume_name" || return 1
}


main || exit 1