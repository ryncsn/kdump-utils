#!/bin/sh

. /lib/dracut-lib.sh

set -x
KDUMP_PATH="/var/crash"
CORE_COLLECTOR="makedumpfile -c --message-level 1 -d 31"
DEFAULT_ACTION="dump_rootfs"
DATEDIR=`date +%d.%m.%y-%T`
DUMP_INSTRUCTION=""
SSH_KEY_LOCATION="/root/.ssh/kdump_id_rsa"
KDUMP_SCRIPT_DIR="/kdumpscripts"
DD_BLKSIZE=512

export PATH=$PATH:$KDUMP_SCRIPT_DIR

# we use manual setup nics in udev rules,
# so we need to test network is really ok
wait_for_net_ok() {
    local ip=$(getarg ip)
    local iface=`echo $ip|cut -d':' -f1`
    return $(wait_for_route_ok $iface)
}

do_default_action()
{
    wait_for_loginit
    $DEFAULT_ACTION
}

add_dump_code()
{
    DUMP_INSTRUCTION="$1 || do_default_action"
}

get_mp()
{
    local _mp
    local dev mp fs opts rest
    while read dev mp fs opts rest; do
        if [ "$dev" = "$1" ]; then
            _mp="$mp"
            break
        fi
    done < /proc/mounts
    echo "$_mp"
}

to_dev_name()
{
    local dev="$1"

    case "$dev" in
    UUID=*)
        dev=`blkid -U "${dev#UUID=}"`
        ;;
    LABEL=*)
        dev=`blkid -L "${dev#LABEL=}"`
        ;;
    esac
    echo $dev
}

dump_localfs()
{
    local _dev=`to_dev_name $1`
    local _mp=`get_mp $_dev`
    if [ "$_mp" = "$NEWROOT/" ] || [ "$_mp" = "$NEWROOT" ]
    then
        mount -o remount,rw $_mp || return 1
    fi
    mkdir -p $_mp/$KDUMP_PATH/$DATEDIR
    $CORE_COLLECTOR /proc/vmcore $_mp/$KDUMP_PATH/$DATEDIR/vmcore || return 1
    umount $_mp || return 1
    return 0
}

dump_raw()
{
    [ -b "$1" ] || return 1

    echo "Saving to raw disk $1"
    if $(echo -n $CORE_COLLECTOR|grep -q makedumpfile); then
        _src_size_mb="Unknown"
    else
        _src_size=`ls -l /proc/vmcore | cut -d' ' -f5`
        _src_size_mb=$(($_src_size / 1048576))
    fi

    monitor_dd_progress $_src_size_mb &

    CORE_COLLECTOR=`echo $CORE_COLLECTOR | sed -e's/\(^makedumpfile\)\(.*$\)/\1 -F \2/'`
    $CORE_COLLECTOR /proc/vmcore | dd of=$1 bs=$DD_BLKSIZE >> /tmp/dd_progress_file 2>&1 || return 1
    return 0
}

dump_rootfs()
{
    mount -o remount,rw $NEWROOT/ || return 1
    mkdir -p $NEWROOT/$KDUMP_PATH/$DATEDIR
    $CORE_COLLECTOR /proc/vmcore $NEWROOT/$KDUMP_PATH/$DATEDIR/vmcore || return 1
    sync
}

dump_nfs()
{
    mount -o remount,rw $NEWROOT/ || return 1
    [ -d $NEWROOT/mnt ] || mkdir -p $NEWROOT/mnt
    mount -o nolock -o tcp -t nfs $1 $NEWROOT/mnt/ || return 1
    mkdir -p $NEWROOT/mnt/$KDUMP_PATH/$DATEDIR || return 1
    $CORE_COLLECTOR /proc/vmcore $NEWROOT/mnt/$KDUMP_PATH/$DATEDIR/vmcore || return 1
    umount $NEWROOT/mnt/ || return 1
    return 0
}

dump_ssh()
{
    ssh -q -i $1 -o BatchMode=yes -o StrictHostKeyChecking=yes $2 mkdir -p $KDUMP_PATH/$DATEDIR || return 1
    scp -q -i $1 -o BatchMode=yes -o StrictHostKeyChecking=yes /proc/vmcore "$2:$KDUMP_PATH/$DATEDIR"  || return 1
    return 0
}

read_kdump_conf()
{
    local conf_file="/etc/kdump.conf"
    if [ -f "$conf_file" ]; then
        # first get the necessary variables
        while read config_opt config_val;
        do
            case "$config_opt" in
            path)
                KDUMP_PATH="$config_val"
                ;;
            core_collector)
                [ -n "$config_val" ] && CORE_COLLECTOR="$config_val"
                ;;
            sshkey)
                if [ -f "$config_val" ]; then
                    SSH_KEY_LOCATION=$config_val
                fi
                ;;
            default)
                case $config_val in
                    shell)
                        DEFAULT_ACTION="sh -i -l"
                        ;;
                    reboot)
                        DEFAULT_ACTION="reboot -f"
                        ;;
                    halt)
                        DEFAULT_ACTION="halt -f"
                        ;;
                    poweroff)
                        DEFAULT_ACTION="poweroff -f"
                        ;;
                esac
                ;;
            esac
        done < $conf_file

        # rescan for add code for dump target
        while read config_opt config_val;
        do
            case "$config_opt" in
            ext[234]|xfs|btrfs|minix)
                add_dump_code "dump_localfs $config_val"
                ;;
            raw)
                add_dump_code "dump_raw $config_val"
                ;;
            net)
                wait_for_net_ok
                if [[ "$config_val" =~ "@" ]]; then
                    add_dump_code "dump_ssh $SSH_KEY_LOCATION $config_val"
                else
                    add_dump_code "dump_nfs $config_val"
                fi
                ;;
            esac
        done < $conf_file
    fi
}

read_kdump_conf

if [ -z "$DUMP_INSTRUCTION" ]; then
    add_dump_code "dump_rootfs"
fi

eval "$DUMP_INSTRUCTION; reboot -f"
