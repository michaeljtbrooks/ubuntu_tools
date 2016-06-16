#!/bin/bash
###############################################################################
#  simple script to set some parameters to increase performance on a mdadm
# raid5 or raid6. Adjust the ## parameters ##-section to your system!
#
#  WARNING: depending on stripe-size and the number of devices the array might
# use QUITE a lot of memory after optimization!
#
#  27may2010 by Alexander Peganz
###############################################################################


## parameters ##
MDDEV=md0               # e.g. md0 for /dev/md0
CHUNKSIZE=1024          # in kb
BLOCKSIZE=4             # of file system in kb
NCQ=disable             # disable, enable. ath. else keeps current setting
NCQDEPTH=31             # 31 should work for almost anyone
FORCECHUNKSIZE=true     # force max sectors kb to chunk size > 512
DOTUNEFS=true           # run tune2fs, ONLY SET TO true IF YOU USE EXT[34]
RAIDLEVEL=raid10         # raid5, raid6, raid10


## code ##
# test for privileges
if [ "$(whoami)" != 'root' ]
then
  echo $(date): Need to be root >> /root/tuneraid.log
  exit 1
fi

# set number of parity devices
if [[ $RAIDLEVEL == "raid6" ]]
then
  NUMPARITY=2
elif [[ $RAIDLEVEL == "raid10" ]]
then
  NUMPARITY=0
else
  NUMPARITY=1
fi

# get all devices
DEVSTR="`grep \"^$MDDEV : \" /proc/mdstat` eol"
while \
 [ -z "`expr match \"$DEVSTR\" '\(\<sd[a-z]1\[[12]\?[0-9]\]\((S)\)\? \)'`" ]
do
  DEVSTR="`echo $DEVSTR|cut -f 2- -d \ `"
done

# get active devices list and spares list
DEVS=""
SPAREDEVS=""
while [ "$DEVSTR" != "eol" ]; do
  CURDEV="`echo $DEVSTR|cut -f -1 -d \ `"
  if [ -n "`expr match \"$CURDEV\" '\(\<sd[a-z]1\[[12]\?[0-9]\]\((S)\)\)'`" ]
  then
    SPAREDEVS="$SPAREDEVS${CURDEV:2:1}"
  elif [ -n "`expr match \"$CURDEV\" '\(\<sd[a-z]1\[[12]\?[0-9]\]\)'`" ]
  then
    DEVS="$DEVS${CURDEV:2:1}"
  fi
  DEVSTR="`echo $DEVSTR|cut -f 2- -d \ `"
done
NUMDEVS=${#DEVS}
NUMSPAREDEVS=${#SPAREDEVS}

# test if number of devices makes sense
if [ ${#DEVS} -lt $[1+$NUMPARITY] ]
then
  echo $(date): Need more devices >> /root/tuneraid.log
  exit 1
fi

# set read ahead
RASIZE=$[$NUMDEVS*($NUMDEVS-$NUMPARITY)*2*$CHUNKSIZE]   # in 512b blocks
echo read ahead size per device: $RASIZE blocks \($[$RASIZE/2]kb\)
MDRASIZE=$[$RASIZE*$NUMDEVS]
echo read ahead size of array: $MDRASIZE blocks \($[$MDRASIZE/2]kb\)
blockdev --setra $RASIZE /dev/sd[$DEVS]
blockdev --setra $RASIZE /dev/sd[$SPAREDEVS]
blockdev --setra $MDRASIZE /dev/$MDDEV

# set stripe cache size
STRCACHESIZE=$[$RASIZE/8]                               # in pages per device
echo stripe cache size of devices: $STRCACHESIZE pages \($[$STRCACHESIZE*4]kb\)
echo $STRCACHESIZE > /sys/block/$MDDEV/md/stripe_cache_size

# set max sectors kb
DEVINDEX=0
MINMAXHWSECKB=$(cat /sys/block/sd${DEVS:0:1}/queue/max_hw_sectors_kb)
until [ $DEVINDEX -ge $NUMDEVS ]
do
  DEVLETTER=${DEVS:$DEVINDEX:1}
  MAXHWSECKB=$(cat /sys/block/sd$DEVLETTER/queue/max_hw_sectors_kb)
  if [ $MAXHWSECKB -lt $MINMAXHWSECKB ]
  then
    MINMAXHWSECKB=$MAXHWSECKB
  fi
  DEVINDEX=$[$DEVINDEX+1]
done
if [ $CHUNKSIZE -le $MINMAXHWSECKB ] &&
  ( [ $CHUNKSIZE -le 512 ] || [[ $FORCECHUNKSIZE == "true" ]] )
then
  echo setting max sectors kb to match chunk size
  DEVINDEX=0
  until [ $DEVINDEX -ge $NUMDEVS ]
  do
    DEVLETTER=${DEVS:$DEVINDEX:1}
    echo $CHUNKSIZE > /sys/block/sd$DEVLETTER/queue/max_sectors_kb
    DEVINDEX=$[$DEVINDEX+1]
  done
  DEVINDEX=0
  until [ $DEVINDEX -ge $NUMSPAREDEVS ]
  do
    DEVLETTER=${SPAREDEVS:$DEVINDEX:1}
    echo $CHUNKSIZE > /sys/block/sd$DEVLETTER/queue/max_sectors_kb
    DEVINDEX=$[$DEVINDEX+1]
  done
fi

# enable/disable NCQ
DEVINDEX=0
if [[ $NCQ == "enable" ]] || [[ $NCQ == "disable" ]]
then
  if [[ $NCQ == "disable" ]]
  then
    NCQDEPTH=1
  fi
  echo setting NCQ queue depth to $NCQDEPTH
  until [ $DEVINDEX -ge $NUMDEVS ]
  do
    DEVLETTER=${DEVS:$DEVINDEX:1}
    echo $NCQDEPTH > /sys/block/sd$DEVLETTER/device/queue_depth
    DEVINDEX=$[$DEVINDEX+1]
  done
  DEVINDEX=0
  until [ $DEVINDEX -ge $NUMSPAREDEVS ]
  do
    DEVLETTER=${SPAREDEVS:$DEVINDEX:1}
    echo $NCQDEPTH > /sys/block/sd$DEVLETTER/device/queue_depth
    DEVINDEX=$[$DEVINDEX+1]
  done
fi

# tune2fs
if [[ $DOTUNEFS == "true" ]]
then
  STRIDE=$[$CHUNKSIZE/$BLOCKSIZE]
  STRWIDTH=$[$CHUNKSIZE/$BLOCKSIZE*($NUMDEVS-$NUMPARITY)]
  echo setting stride to $STRIDE blocks \($CHUNKSIZEkb\)
  echo setting stripe-width to $STRWIDTH blocks \($[$STRWIDTH*$BLOCKSIZE]kb\)
  tune2fs -E stride=$STRIDE,stripe-width=$STRWIDTH /dev/$MDDEV
fi

echo $(date): Success >> /root/tuneraid.log
