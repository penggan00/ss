cat <<"EOF" > /etc/init.d/mount_hp
#!/bin/sh /etc/rc.common
START=99
STOP=15

boot() {
    logger -t mount_hp "启动双硬盘挂载流程"
    
    # 动态等待硬盘（最多30秒）
    retries=10
    while [ $retries -gt 0 ]; do
        [ -b /dev/sda1 -a -b /dev/sdb1 ] && break
        sleep 3
        retries=$((retries-1))
        logger -t mount_hp "等待硬盘设备...剩余尝试 $retries 次"
    done

    # 智能挂载函数
    mount_disk() {
        local dev=$1 uuid=$2 mnt=$3
        [ ! -b $dev ] && { logger -t mount_hp "$dev 不存在"; return 1; }
        
        mkdir -p $mnt
        if mountpoint -q $mnt; then
            logger -t mount_hp "$mnt 已挂载"
            return 0
        fi
        
        if ! mount UUID=$uuid $mnt 2>/dev/null; then
            logger -t mount_hp "开始修复 $dev"
            fsck -p $dev
            mount UUID=$uuid $mnt || {
                logger -t mount_hp "$dev 最终挂载失败"
                return 1
            }
        fi
        logger -t mount_hp "$dev 成功挂载到 $mnt"
    }

    # 并行挂载两块硬盘
    mount_disk /dev/sda1 0da13076-ccf7-4bd3-8d54-0b51bb4b33f5 /mnt/hp &
    mount_disk /dev/sdb1 e0280430-4e37-471a-b784-ad948d7e48f4 /mnt/hp1 &
    wait

    # 验证结果
    df -h | grep -E 'hp|Filesystem' | logger -t mount_hp
}

start() { boot; }
EOF