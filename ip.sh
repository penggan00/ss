# 查看所有监狱的封禁统计
echo "=== 当前封禁IP统计 ==="
echo "总封禁IP数:"

# 1. sshd监狱
SSHD_COUNT=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $4}')
SSHD_TOTAL=$(fail2ban-client status sshd 2>/dev/null | grep "Total banned" | awk '{print $4}')
echo "sshd监狱:"
echo "  当前封禁: $SSHD_COUNT 个IP"
echo "  累计封禁: $SSHD_TOTAL 个IP"

# 2. recidive-short监狱
REC_SHORT_COUNT=$(fail2ban-client status recidive-short 2>/dev/null | grep "Currently banned" | awk '{print $4}')
REC_SHORT_TOTAL=$(fail2ban-client status recidive-short 2>/dev/null | grep "Total banned" | awk '{print $4}')
echo "recidive-short监狱:"
echo "  当前封禁: $REC_SHORT_COUNT 个IP"
echo "  累计封禁: $REC_SHORT_TOTAL 个IP"

# 3. recidive-long监狱
REC_LONG_COUNT=$(fail2ban-client status recidive-long 2>/dev/null | grep "Currently banned" | awk '{print $4}')
REC_LONG_TOTAL=$(fail2ban-client status recidive-long 2>/dev/null | grep "Total banned" | awk '{print $4}')
echo "recidive-long监狱:"
echo "  当前封禁: $REC_LONG_COUNT 个IP"
echo "  累计封禁: $REC_LONG_TOTAL 个IP"

# 4. 去重后的真实封禁IP数
echo -e "\n=== 去重统计 ==="
echo "从iptables统计实际生效的封禁规则:"

# 统计每个链的封禁规则数
IPTABLES_SSHD=$(iptables -L f2b-sshd -n 2>/dev/null | grep REJECT | wc -l)
IPTABLES_SHORT=$(iptables -L f2b-recidive-short -n 2>/dev/null | grep REJECT | wc -l)
IPTABLES_LONG=$(iptables -L f2b-recidive-long -n 2>/dev/null | grep REJECT | wc -l)

echo "f2b-sshd链: $IPTABLES_SSHD 条封禁规则"
echo "f2b-recidive-short链: $IPTABLES_SHORT 条封禁规则"
echo "f2b-recidive-long链: $IPTABLES_LONG 条封禁规则"

TOTAL_IPTABLES=$((IPTABLES_SSHD + IPTABLES_SHORT + IPTABLES_LONG))
echo "总计: $TOTAL_IPTABLES 条iptables封禁规则"

# 5. 查看具体的封禁IP示例
echo -e "\n=== 封禁IP示例（每个监狱前5个）==="
echo "sshd监狱封禁的IP:"
iptables -L f2b-sshd -n 2>/dev/null | grep REJECT | head -5 | awk '{print "  " $4}'

echo -e "\nrecidive-short监狱封禁的IP:"
iptables -L f2b-recidive-short -n 2>/dev/null | grep REJECT | head -5 | awk '{print "  " $4}'

echo -e "\nrecidive-long监狱封禁的IP:"
iptables -L f2b-recidive-long -n 2>/dev/null | grep REJECT | head -5 | awk '{print "  " $4}'

# 6. 查看封禁时间
echo -e "\n=== 封禁时间分析 ==="
echo "当前时间: $(date)"
echo "封禁规则数量随时间变化:"
for hours in 1 6 24 168; do
    COUNT=$(iptables -L -n -v | grep REJECT | awk -v hours=$hours '{if (systime() - strftime("%s", $1" "$2) < hours*3600) print}' | wc -l)
    echo "  最近${hours}小时新增: $COUNT 条"
done

# 7. 查看攻击源统计
echo -e "\n=== 攻击源分析 ==="
echo "最近被封禁的IP网段分布:"
iptables -L -n | grep REJECT | awk '{print $4}' | cut -d. -f1-2 | sort | uniq -c | sort -rn | head -10 | \
while read count net; do
    echo "  ${net}.x.x: $count 个IP"
done