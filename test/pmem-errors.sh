#!/bin/bash -x
# SPDX-License-Identifier: GPL-2.0
# Copyright(c) 2015-2017 Intel Corporation. All rights reserved.

DEV=""
NDCTL="../ndctl/ndctl"
BUS="-b nfit_test.0"
BUS1="-b nfit_test.1"
MNT=test_dax_mnt
FILE=image
json2var="s/[{}\",]//g; s/:/=/g"
rc=77

err() {
	echo "test/dax-errors: failed at line $1"
	rm -f $FILE
	rm -f $MNT/$FILE
	if [ -n "$blockdev" ]; then
		umount /dev/$blockdev
	else
		rc=77
	fi
	rmdir $MNT
	exit $rc
}

check_min_kver()
{
	local ver="$1"
	: "${KVER:=$(uname -r)}"

	[ -n "$ver" ] || return 1
	[[ "$ver" == "$(echo -e "$ver\n$KVER" | sort -V | head -1)" ]]
}

check_min_kver "4.7" || { echo "kernel $KVER may lack dax error handling"; exit $rc; }

set -e
mkdir -p $MNT
trap 'err $LINENO' ERR

# setup (reset nfit_test dimms)
modprobe nfit_test
$NDCTL disable-region $BUS all
$NDCTL zero-labels $BUS all
$NDCTL enable-region $BUS all

rc=1

# create pmem
dev="x"
json=$($NDCTL create-namespace $BUS -t pmem -m raw)
eval $(echo $json | sed -e "$json2var")
[ $dev = "x" ] && echo "fail: $LINENO" && false
[ $mode != "raw" ] && echo "fail: $LINENO" && false

# inject errors in the middle of the namespace, verify that reading fails
err_sector="$(((size/512) / 2))"
err_count=8
if ! read sector len < /sys/block/$blockdev/badblocks; then
	$NDCTL inject-error --block="$err_sector" --count=$err_count $dev
	$NDCTL start-scrub; $NDCTL wait-scrub
fi
read sector len < /sys/block/$blockdev/badblocks
[ $((sector * 2)) -ne $((size /512)) ] && echo "fail: $LINENO" && false
if dd if=/dev/$blockdev of=/dev/null iflag=direct bs=512 skip=$sector count=$len; then
	echo "fail: $LINENO" && false
fi

# check that writing clears the errors
if ! dd of=/dev/$blockdev if=/dev/zero oflag=direct bs=512 seek=$sector count=$len; then
	echo "fail: $LINENO" && false
fi

if read sector len < /sys/block/$blockdev/badblocks; then
	# fail if reading badblocks returns data
	echo "fail: $LINENO" && false
fi

#mkfs.xfs /dev/$blockdev -b size=4096 -f
mkfs.ext4 /dev/$blockdev -b 4096
mount /dev/$blockdev $MNT

# prepare an image file with random data
dd if=/dev/urandom of=$MNT/$FILE bs=4096 count=4 oflag=direct

# Get the start sector for the file
start_sect=$(filefrag -v -b512 $MNT/$FILE | grep -E "^[ ]+[0-9]+.*" | head -1 | awk '{ print $4 }' | cut -d. -f1)
test -n "$start_sect"
echo "start sector of the file is $start_sect"

# inject badblocks for one page at the start of the file
echo $start_sect 8 > /sys/block/$blockdev/badblocks

# make sure reading the first block of the file fails as expected
: The following 'dd' is expected to hit an I/O Error
dd if=$MNT/$FILE of=/dev/null iflag=direct bs=4096 count=1 && err $LINENO || true

# run the dax-errors test
test -x ./dax-errors
./dax-errors $MNT/$FILE

# TODO: disable this check till we have clear-on-write in the kernel
#if read sector len < /sys/block/$blockdev/badblocks; then
#	# fail if reading badblocks returns data
#	echo "fail: $LINENO" && false
#fi

# TODO Due to the above, we have to clear the existing badblock manually
read sector len < /sys/block/$blockdev/badblocks
if ! dd of=/dev/$blockdev if=/dev/zero oflag=direct bs=512 seek=$sector count=$len; then
	echo "fail: $LINENO" && false
fi


# test that a hole punch to a dax file also clears errors
dd if=/dev/urandom of=$MNT/$FILE oflag=direct bs=4096 count=4
start_sect=$(filefrag -v -b512 $MNT/$FILE | grep -E "^[ ]+[0-9]+.*" | head -1 | awk '{ print $4 }' | cut -d. -f1)
test -n "$start_sect"
echo "holepunch test: start sector: $start_sect"

# inject a badblock at the second sector of the first page
echo $((start_sect + 1)) 1 > /sys/block/$blockdev/badblocks

# verify badblock by reading
: The following 'dd' is expected to hit an I/O Error
dd if=$MNT/$FILE of=/dev/null iflag=direct bs=4096 count=1 && err $LINENO || true

# cleanup
rm -f $FILE
rm -f $MNT/$FILE
if [ -n "$blockdev" ]; then
	umount /dev/$blockdev
fi
rmdir $MNT

$NDCTL disable-region $BUS all
$NDCTL disable-region $BUS1 all
modprobe -r nfit_test

exit 0
