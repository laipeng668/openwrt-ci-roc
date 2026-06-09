#!/bin/bash
set -eo pipefail

# ============================================
# AX5 Stable Build for LiBwrt/openwrt-6.x
# 版本: v9.5 Final Stable
# 设备: 红米 AX5 / AX5 JDCloud (512M + WiFi)
# 默认主题: Argon
# IRQ: 自动调优 (RPS+RFS)
# NSS-DP: PHY 禁止过度管理 (防抖动)
# 科学上网: PassWall
# 网络: PPPoE IPv4 + IPv6 双栈 + 防火墙优化
# 上游同步: 自动兼容上游 NSS 内核更新
# 适配: Ubuntu 24.04 + GitHub Actions Node.js 24
# ============================================

red()    { printf "\033[31m%s\033[0m\n" "$1"; }
green()  { printf "\033[32m%s\033[0m\n" "$1"; }
yellow() { printf "\033[33m%s\033[0m\n" "$1"; }

export OPENWRT_PATH="${OPENWRT_PATH:-$(pwd)}"
cd "$OPENWRT_PATH" || exit 1

# ============================================
# 0. 稳定性预检 + 上游 NSS 兼容
# ============================================
green "====0 Stability & Upstream Compat===="

find . -name "*.sh" -exec chmod +x {} + 2>/dev/null || true
find . -name "configure" -exec chmod +x {} + 2>/dev/null || true
rm -f /tmp/.package* /tmp/opkg* /tmp/*.lock 2>/dev/null || true

for dir in package target tools include scripts; do
  [ -d "$dir" ] || { red "❌ 缺少目录: $dir"; exit 1; }
done

KERNEL_VER="6.12"
_kv=$(grep -oP 'LINUX_VERSION-\d+\.\d+=\K.*' include/kernel-version.mk 2>/dev/null || true)
[ -n "$_kv" ] && KERNEL_VER="$_kv"
green "检测内核: $KERNEL_VER"

fix_nss_compat() {
    local kver="$1"
    local major=$(echo "$kver" | cut -d. -f1)
    local minor=$(echo "$kver" | cut -d. -f2)
    
    if [ "$major" -ge 6 ] && [ "$minor" -ge 1 ]; then
        for f in $(find feeds package -name "*.c" -path "*/nss/*" 2>/dev/null); do
            if grep -q "setup_timer" "$f" 2>/dev/null; then
                sed -i 's/setup_timer(\([^,]*\), \([^,]*\), [^)]*)/timer_setup(\1, \2, 0)/g' "$f" 2>/dev/null || true
            fi
        done
    fi
    
    if [ "$major" -ge 6 ] && [ "$minor" -ge 5 ]; then
        for f in $(find feeds package -name "*.c" -path "*/nss/*" 2>/dev/null); do
            if grep -q "netif_napi_add.*,.*,.*,.*[0-9]" "$f" 2>/dev/null; then
                sed -i 's/netif_napi_add(\([^,]*\), \([^,]*\), \([^,]*\), [0-9]*)/netif_napi_add(\1, \2, \3)/g' "$f" 2>/dev/null || true
            fi
        done
    fi
    
    if [ "$major" -ge 6 ] && [ "$minor" -ge 12 ]; then
        for f in $(find feeds package -name "*.c" -name "*.h" -path "*/nss/*" 2>/dev/null); do
            sed -i 's/PDE_DATA(/pde_data(/g' "$f" 2>/dev/null || true
        done
    fi
}

fix_nss_compat "$KERNEL_VER"
green "✅ NSS 内核兼容性已适配 (Linux $KERNEL_VER)"

green "====0 Environment Init===="

LIbwrt_VER=$(git rev-parse --short HEAD 2>/dev/null || true)
[ -z "$LIbwrt_VER" ] && LIbwrt_VER="unknown"
green "LiBwrt: $LIbwrt_VER | Kernel: $KERNEL_VER"

mkdir -p package/base-files/files/etc/uci-defaults
mkdir -p package/base-files/files/etc/hotplug.d/iface
mkdir -p package/base-files/files/usr/bin

# ============================================
# 1. Feed 初始化
# ============================================
green "====1 Feed Init===="
if [ ! -f feeds.conf ] && [ ! -f feeds.conf.default ]; then
    red "Error: No feeds.conf / feeds.conf.default found!"
    exit 1
fi

FEED_OK=0
for i in {1..3}; do
    if ./scripts/feeds update -a; then
        FEED_OK=1
        break
    fi
    yellow "Feed update retry $i/3 ..."
    sleep 8
done

[ $FEED_OK -ne 1 ] && yellow "Feed update warning, continue..."

./scripts/feeds install -a 2>/dev/null || true
./scripts/feeds install coreutils ca-bundle jq curl libopenssl-legacy 2>/dev/null || true

# ============================================
# 2. 冲突彻底清理（全优版）
# ============================================
green "====2 Conflict Removal===="

CONFLICT_MODULES="qca-nss-ppe qca-nss-ecm-nat qca-nss-drv-cake qca-nss-drv-wifi zram-backend-lzo"
for mod in $CONFLICT_MODULES; do
    find . -path "*/$mod*" -type d 2>/dev/null | while read -r dir; do
        [ -d "$dir" ] && rm -rf "$dir" 2>/dev/null || true
    done
done

find package feeds -name "Makefile" 2>/dev/null | while read -r mk_file; do
    for kmod in iptunnel4 iptunnel6 ppp-async nf-conntrack6 nf-ipt6 nf-nat6; do
        sed -i "s/+$kmod//g" "$mk_file" 2>/dev/null || true
    done
done

for pkg in frpc frps argon-config argon; do
    count=$(find package feeds -path "*/luci-app-$pkg/Makefile" 2>/dev/null | wc -l)
    if [ "$count" -gt 1 ]; then
        find feeds -path "*/luci-app-$pkg" -type d -exec rm -rf {} + 2>/dev/null || true
    fi
done

if [ -f .config ]; then
    MUST_COMMENT=(
        "CONFIG_PACKAGE_kmod-qca-nss-ecm-nat"
        "CONFIG_PACKAGE_kmod-qca-nss-drv-cake"
        "CONFIG_PACKAGE_kmod-qca-nss-drv-wifi"
        "CONFIG_PACKAGE_kmod-qca-nss-ppe"
        "CONFIG_KERNEL_ZRAM_BACKEND_LZO"
        "CONFIG_PACKAGE_kmod-sched-cake"
        "CONFIG_TARGET_PER_DEVICE_ROOTFS"
        "CONFIG_FEED_nss_packages"
        "CONFIG_TARGET_ROOTFS_INITRAMFS"
        "CONFIG_KERNEL_PREEMPT_RT"
    )
    
    for key in "${MUST_COMMENT[@]}"; do
        sed -i "/^${key}[= ]/d; /^# ${key} is not set/d" .config 2>/dev/null || true
        echo "# ${key} is not set" >> .config
    done
    
    for kmod in iptunnel4 iptunnel6 ppp-async nf-conntrack6 nf-ipt6 nf-nat6; do
        sed -i "/CONFIG_PACKAGE_kmod-$kmod/d" .config 2>/dev/null || true
    done
fi

# ============================================
# 3. 基础配置
# ============================================
green "====3 Base Config===="
if [ -f package/base-files/files/bin/config_generate ]; then
    if ! grep -q "192.168.10.1" package/base-files/files/bin/config_generate 2>/dev/null; then
        sed -i 's/192.168.1.1/192.168.10.1/g' package/base-files/files/bin/config_generate 2>/dev/null || true
    fi
    if ! grep -q "hostname='AX5'" package/base-files/files/bin/config_generate 2>/dev/null; then
        sed -i "s/hostname='.*'/hostname='AX5'/g" package/base-files/files/bin/config_generate 2>/dev/null || true
    fi
fi

DTS_LIST=(
    target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi
    target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq60xx/ipq6018-512m.dtsi
)
for dts in "${DTS_LIST[@]}"; do
    if [ -f "$dts" ] && ! grep -q "0x04000000" "$dts" 2>/dev/null; then
        sed -i '/nss\|reserved/{s/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x04000000>/}' "$dts" 2>/dev/null || true
        green "DTS patched: $dts"
        break
    fi
done

# ============================================
# 4. 插件拉取
# ============================================
green "====4 Plugins===="

rm -rf feeds/luci/applications/luci-app-argon-config 2>/dev/null || true
rm -rf feeds/luci/themes/luci-theme-argon 2>/dev/null || true
rm -rf feeds/luci/applications/luci-app-frpc 2>/dev/null || true
rm -rf feeds/luci/applications/luci-app-frps 2>/dev/null || true
rm -rf feeds/luci/applications/luci-app-passwall 2>/dev/null || true
rm -rf feeds/packages/net/{xray-core,v2ray-geodata,sing-box,chinadns-ng,dns2socks,hysteria,ipt2socks,microsocks,naiveproxy,shadowsocks-libev,shadowsocks-rust,shadowsocksr-libev,simple-obfs,tcping,trojan-plus,tuic-client,v2ray-plugin,xray-plugin,geoview,shadow-tls} 2>/dev/null || true

clone_repo() {
    local repo_url="$1"
    local target_dir="$2"
    local name="$3"
    if [ -d "$target_dir/.git" ] || [ -f "$target_dir/Makefile" ]; then
        green "  ✓ $name exists, skip clone"
        return 0
    fi
    if git clone --depth=1 --single-branch "$repo_url" "$target_dir" 2>/dev/null; then
        green "  ✓ $name cloned"
    else
        yellow "  ✗ $name clone failed"
    fi
    return 0
}

clone_repo "https://github.com/jerrykuku/luci-theme-argon"       "feeds/luci/themes/luci-theme-argon"          "argon-theme"
clone_repo "https://github.com/jerrykuku/luci-app-argon-config"  "feeds/luci/applications/luci-app-argon-config" "argon-config"
clone_repo "https://github.com/gdy666/luci-app-lucky"            "package/luci-app-lucky"                      "lucky"
clone_repo "https://github.com/destan19/OpenAppFilter.git"       "package/OpenAppFilter"                       "OAF"

if [ ! -d feeds/luci/applications/luci-app-frpc ] && [ ! -d package/luci-app-frpc ]; then
    clone_repo "https://github.com/laipeng668/luci" "feeds/_tmpfrp" "frp"
    if [ -d feeds/_tmpfrp/applications/luci-app-frpc ]; then
        mv feeds/_tmpfrp/applications/luci-app-frpc feeds/luci/applications/ 2>/dev/null || true
        mv feeds/_tmpfrp/applications/luci-app-frps feeds/luci/applications/ 2>/dev/null || true
    fi
    rm -rf feeds/_tmpfrp 2>/dev/null || true
fi

clone_repo "https://github.com/Openwrt-Passwall/openwrt-passwall-packages" "package/passwall-packages" "passwall-packages"
clone_repo "https://github.com/Openwrt-Passwall/openwrt-passwall"          "package/luci-app-passwall"  "passwall"
echo "baidu.com" > package/luci-app-passwall/luci-app-passwall/root/usr/share/passwall/rules/chnlist 2>/dev/null || true

# ============================================
# 5. NSS 驱动内核兼容补丁
# ============================================
green "====5 NSS Adapt===="
NSS_DIRS=$(find feeds package -maxdepth 4 -type d \( -name "qca-nss*" -o -name "qca-ssdk" \) 2>/dev/null | grep -v ppe || true)

if [ -n "$NSS_DIRS" ]; then
    for f in $(find $NSS_DIRS -name "*.c" -o -name "*.h" 2>/dev/null || true); do
        [ ! -f "${f}.bak" ] && cp "$f" "${f}.bak" 2>/dev/null || true
        if grep -q "setup_timer" "$f" 2>/dev/null; then
            sed -i 's/setup_timer(\(&[^,]*\), \([^,]*\), \([^)]*\))/timer_setup(\1, \2, 0)/g' "$f" 2>/dev/null || true
            perl -i -0pe 's/setup_timer\s*\(\s*([^,]+)\s*,\s*([^,]+)\s*,\s*[^)]+\s*\)/timer_setup($1, $2, 0)/gs' "$f" 2>/dev/null || true
        fi
        if grep -q "netif_napi_add" "$f" 2>/dev/null; then
            sed -i 's/netif_napi_add(\([^,]*\), \([^,]*\), \([^,]*\), [0-9]*)/netif_napi_add(\1, \2, \3)/g' "$f" 2>/dev/null || true
        fi
    done
    for mk in $(find $NSS_DIRS -name "Makefile" 2>/dev/null || true); do
        if grep -q "KERNEL_PATCHVER" "$mk" 2>/dev/null; then
            sed -i "s/KERNEL_PATCHVER:=6\.[0-9]*/KERNEL_PATCHVER:=$KERNEL_VER/g" "$mk" 2>/dev/null || true
        fi
    done
fi

# ============================================
# 6. 启动顺序优化
# ============================================
green "====6 Startup Order===="

optimize_start() {
    local file="$1"
    local start_num="$2"
    [ ! -f "$file" ] || [ ! -w "$file" ] && return 0
    sed -i "s/START=[0-9]*/START=$start_num/" "$file" 2>/dev/null || true
    sed -i "s/USE_PROCD=.*/USE_PROCD=1/" "$file" 2>/dev/null || true
}

find feeds package \( -name "qca-ssdk.init" -o -name "qca-nss-drv.init" -o -name "qca-nss-dp.init" -o -name "qca-nss-ecm.init" \) 2>/dev/null | while read -r init; do
    case "$init" in
        *ssdk*)    optimize_start "$init" 10 ;;
        *nss-drv*) optimize_start "$init" 11 ;;
        *nss-dp*)  optimize_start "$init" 12 ;;
        *nss-ecm*) optimize_start "$init" 13 ;;
    esac
done

SVC_LIST=(
    "package/base-files/files/etc/init.d/boot:15"
    "package/system/zram-swap/files/zram-swap.init:16"
    "package/base-files/files/etc/init.d/network:20"
    "package/network/services/dnsmasq/files/dnsmasq.init:21"
    "package/network/config/firewall4/files/firewall.init:23"
    "feeds/packages/net/zerotier/files/zerotier.init:32"
    "package/network/services/uhttpd/files/uhttpd.init:40"
    "package/system/rpcd/files/rpcd.init:41"
    "package/network/services/odhcpd/files/odhcpd.init:42"
)
for svc in "${SVC_LIST[@]}"; do
    f="${svc%%:*}"
    s="${svc##*:}"
    optimize_start "$f" "$s"
done

green "启动顺序: SSDK(10) → NSS-DRV(11) → NSS-DP(12) → NSS-ECM(13) → 网络(20) → Zerotier(32) → 服务(40+) → odhcpd(42)"

# ============================================
# 7. 编译补丁
# ============================================
green "====7 Patches===="
TS=$(find feeds/packages -maxdepth 3 -name "tailscale/Makefile" 2>/dev/null | head -1)
[ -f "$TS" ] && grep -q "/files" "$TS" 2>/dev/null && sed -i '/\/files/d' "$TS" 2>/dev/null || true

RU=$(find feeds/packages -maxdepth 3 -name "rust/Makefile" 2>/dev/null | head -1)
[ -f "$RU" ] && grep -q "ci-llvm=true" "$RU" 2>/dev/null && sed -i 's/ci-llvm=true/ci-llvm=false/' "$RU" 2>/dev/null || true

# ============================================
# 8. 系统预置 uci-defaults
# ============================================
green "====8 System Presets===="

cat > package/base-files/files/etc/uci-defaults/95-lang <<'EOF'
#!/bin/sh
uci -q get system.@system[0].zonename >/dev/null || uci set system.@system[0].zonename='Asia/Shanghai'
uci -q get system.@system[0].timezone >/dev/null || uci set system.@system[0].timezone='CST-8'
uci set luci.main.lang='zh_cn'
uci commit system 2>/dev/null; uci commit luci 2>/dev/null
EOF

cat > package/base-files/files/etc/uci-defaults/88-fs <<'EOF'
#!/bin/sh
mount -o remount,noatime / 2>/dev/null || true
[ -w /proc/sys/kernel/printk ] && echo "3 4 1 3" > /proc/sys/kernel/printk 2>/dev/null || true
mountpoint -q /tmp || mount -t tmpfs tmpfs /tmp 2>/dev/null || true
grep -q "fs.file-max=65536" /etc/sysctl.conf 2>/dev/null || echo "fs.file-max=65536" >> /etc/sysctl.conf
EOF

cat > package/base-files/files/etc/uci-defaults/90-throughput <<'EOF'
#!/bin/sh
echo 10 >/proc/sys/vm/dirty_ratio 2>/dev/null || true
echo 5 >/proc/sys/vm/dirty_background_ratio 2>/dev/null || true
total_mem=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 524288)
[ "$total_mem" -gt 1048576 ] && echo 8192 >/proc/sys/vm/min_free_kbytes || echo 2048 >/proc/sys/vm/min_free_kbytes
a() { grep -q "$1" /etc/sysctl.conf 2>/dev/null || echo "$1" >> /etc/sysctl.conf; }
a "net.ipv4.tcp_fastopen=3"; a "net.core.default_qdisc=fq"; a "net.ipv4.tcp_congestion_control=bbr"
a "net.ipv4.tcp_rmem=4096 131072 8388608"; a "net.ipv4.tcp_wmem=4096 65536 6291456"
a "net.core.rmem_max=16777216"; a "net.core.wmem_max=16777216"
a "net.ipv4.tcp_tw_reuse=1"; a "net.ipv4.tcp_keepalive_time=60"; a "net.ipv4.tcp_fin_timeout=10"
a "net.ipv4.tcp_max_syn_backlog=16384"; a "net.core.somaxconn=8192"
a "net.core.netdev_max_backlog=8192"; a "net.core.netdev_budget=800"
a "net.netfilter.nf_conntrack_max=65535"; a "net.netfilter.nf_conntrack_timestamp=0"
a "net.netfilter.nf_conntrack_early_offload=1"; a "net.netfilter.nf_conntrack_tcp_timeout_established=3600"
a "net.ipv4.udp_mem=65536 131072 262144"
a "net.ipv4.tcp_slow_start_after_idle=0"; a "net.ipv4.tcp_mtu_probing=1"
a "net.ipv4.tcp_syncookies=1"; a "net.ipv4.ip_forward=1"
a "net.ipv4.conf.all.rp_filter=0"; a "net.ipv4.conf.default.rp_filter=0"
a "net.ipv4.conf.all.accept_redirects=0"; a "net.ipv4.conf.all.send_redirects=0"
a "net.ipv6.conf.all.forwarding=1"; a "net.ipv6.conf.all.accept_ra=2"
a "net.ipv6.conf.all.accept_redirects=0"; a "net.ipv6.conf.all.router_solicitations=3"
[ -d /sys/kernel/debug/nss/flow_preload ] && echo 2 >/sys/kernel/debug/nss/flow_preload/enable 2>/dev/null || true
grep -q "drop_caches" /etc/crontabs/root 2>/dev/null || echo "0 */8 * * * sync;echo 1 >/proc/sys/vm/drop_caches" >> /etc/crontabs/root
/etc/init.d/cron enable 2>/dev/null || true
EOF

cat > package/base-files/files/etc/uci-defaults/91-theme <<'EOF'
#!/bin/sh
uci set luci.main.mediaurlbase='/luci-static/argon'
uci commit luci 2>/dev/null
EOF

cat > package/base-files/files/etc/uci-defaults/92-network <<'EOF'
#!/bin/sh
# ============================================
# 网络 + 防火墙 + IPv4/IPv6 全优配置（幂等版）
# ============================================

# ---------- 清理旧规则 ----------
for s in $(uci show firewall 2>/dev/null | grep -E "Allow-IPv6|Allow-DHCPv6|Allow-ICMPv4|Allow-DHCPv4|Allow-IGMP|ZT-9993" | cut -d= -f1); do
    uci delete "$s" 2>/dev/null || true
done
for s in $(uci show firewall 2>/dev/null | grep "zerotier" | cut -d= -f1); do
    uci delete "$s" 2>/dev/null || true
done
uci commit firewall 2>/dev/null

# ---------- WAN IPv4 优化 ----------
if uci -q get network.wan >/dev/null 2>&1; then
    [ "$(uci -q get network.wan.proto)" = "pppoe" ] && {
        uci -q get network.wan.keepalive >/dev/null || uci set network.wan.keepalive='60 10'
        uci -q get network.wan.mtu >/dev/null || uci set network.wan.mtu='1492'
        uci commit network 2>/dev/null
    }
fi

# ---------- IPv6 WAN6 ----------
if ! uci -q get network.wan6 >/dev/null 2>&1; then
    uci set network.wan6=interface
    uci set network.wan6.proto='dhcpv6'
    uci set network.wan6.device='@wan'
    uci set network.wan6.reqaddress='try'
    uci set network.wan6.reqprefix='auto'
    uci commit network 2>/dev/null
fi

# ---------- 防火墙基础 ----------
uci set firewall.@defaults[0].input='ACCEPT' 2>/dev/null || true
uci set firewall.@defaults[0].output='ACCEPT' 2>/dev/null || true
uci set firewall.@defaults[0].forward='ACCEPT' 2>/dev/null || true
uci set firewall.@defaults[0].fullcone='1' 2>/dev/null || true
uci set firewall.@defaults[0].flow_offloading='1' 2>/dev/null || true
uci set firewall.@defaults[0].flow_offloading_hw='1' 2>/dev/null || true

# ---------- IPv4 ICMP ----------
if ! uci show firewall 2>/dev/null | grep -q "Allow-ICMPv4"; then
    uci add firewall rule
    uci set firewall.@rule[-1].name='Allow-ICMPv4'
    uci set firewall.@rule[-1].src='wan'
    uci set firewall.@rule[-1].proto='icmp'
    uci set firewall.@rule[-1].family='ipv4'
    uci set firewall.@rule[-1].target='ACCEPT'
fi

# ---------- IPv6 ICMP ----------
if ! uci show firewall 2>/dev/null | grep -q "Allow-IPv6-ICMP"; then
    uci add firewall rule
    uci set firewall.@rule[-1].name='Allow-IPv6-ICMP'
    uci set firewall.@rule[-1].src='wan'
    uci set firewall.@rule[-1].proto='icmp'
    uci set firewall.@rule[-1].family='ipv6'
    uci set firewall.@rule[-1].target='ACCEPT'
fi

# ---------- DHCPv6 ----------
if ! uci show firewall 2>/dev/null | grep -q "Allow-DHCPv6"; then
    uci add firewall rule
    uci set firewall.@rule[-1].name='Allow-DHCPv6'
    uci set firewall.@rule[-1].src='wan'
    uci set firewall.@rule[-1].proto='udp'
    uci set firewall.@rule[-1].src_port='546'
    uci set firewall.@rule[-1].dest_port='547'
    uci set firewall.@rule[-1].family='ipv6'
    uci set firewall.@rule[-1].target='ACCEPT'
fi

# ---------- Zerotier ----------
if ! uci show firewall 2>/dev/null | grep -q "name='zerotier'"; then
    uci add firewall zone
    uci set firewall.@zone[-1].name='zerotier'
    uci set firewall.@zone[-1].device='zt+'
    uci set firewall.@zone[-1].input='ACCEPT'
    uci set firewall.@zone[-1].output='ACCEPT'
    uci set firewall.@zone[-1].forward='ACCEPT'
    uci set firewall.@zone[-1].masq='1'
    
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='lan'
    uci set firewall.@forwarding[-1].dest='zerotier'
    
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='zerotier'
    uci set firewall.@forwarding[-1].dest='lan'
    
    uci add firewall rule
    uci set firewall.@rule[-1].name='ZT-9993-UDP'
    uci set firewall.@rule[-1].src='wan'
    uci set firewall.@rule[-1].proto='udp'
    uci set firewall.@rule[-1].dest_port='9993'
    uci set firewall.@rule[-1].target='ACCEPT'
fi

uci commit firewall 2>/dev/null

# ---------- DHCP/DNS ----------
uci -q get dhcp.@dnsmasq[0].cachesize >/dev/null || uci set dhcp.@dnsmasq[0].cachesize='2000'
uci -q get dhcp.@dnsmasq[0].dnsforwardmax >/dev/null || uci set dhcp.@dnsmasq[0].dnsforwardmax='512'
uci set dhcp.@dnsmasq[0].filter_aaaa='0' 2>/dev/null || true
uci set dhcp.@dnsmasq[0].noresolv='0' 2>/dev/null || true
uci commit dhcp 2>/dev/null

# ---------- ECM NSS ----------
if uci -q get ecm >/dev/null 2>&1; then
    uci -q get ecm.@global[0].acceleration_engine >/dev/null || uci set ecm.@global[0].acceleration_engine='nss'
    uci -q get ecm.@global[0].preload_mode >/dev/null || uci set ecm.@global[0].preload_mode='full'
    uci -q get ecm.@global[0].conn_limit >/dev/null || uci set ecm.@global[0].conn_limit='65535'
    uci commit ecm 2>/dev/null
fi

/etc/init.d/zerotier enable 2>/dev/null || true
/etc/init.d/odhcpd enable 2>/dev/null || true
EOF

cat > package/base-files/files/etc/uci-defaults/94-zram <<'EOF'
#!/bin/sh
if [ -d /sys/block/zram0 ]; then
    [ -f /sys/block/zram0/max_comp_streams ] && echo 4 > /sys/block/zram0/max_comp_streams 2>/dev/null || true
    echo 40 > /proc/sys/vm/swappiness 2>/dev/null || true
else
    echo 60 > /proc/sys/vm/swappiness 2>/dev/null || true
fi
EOF

cat > package/base-files/files/etc/uci-defaults/97-irq <<'EOF'
#!/bin/sh
cpu_count=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 4)
mask=$(printf "%x" $(( (1 << cpu_count) - 1 )))

for iface in eth0 eth1 pppoe-wan br-lan; do
    [ -d "/sys/class/net/$iface" ] || continue
    for q in /sys/class/net/$iface/queues/rx-* 2>/dev/null; do echo "$mask" > "$q/rps_cpus" 2>/dev/null || true; done
    for q in /sys/class/net/$iface/queues/tx-* 2>/dev/null; do echo "$mask" > "$q/xps_cpus" 2>/dev/null || true; done
    ip link set dev "$iface" txqueuelen 4000 2>/dev/null || true
done

[ -w /proc/sys/net/core/napi_threaded ] && echo 1 > /proc/sys/net/core/napi_threaded 2>/dev/null || true
[ -w /proc/sys/net/core/rps_sock_flow_entries ] && echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
for iface in eth0 eth1 pppoe-wan br-lan; do
    for q in /sys/class/net/$iface/queues/rx-* 2>/dev/null; do echo 2048 > "$q/rps_flow_cnt" 2>/dev/null || true; done
done
EOF

cat > package/base-files/files/etc/uci-defaults/98-nss <<'EOF'
#!/bin/sh
[ -w /sys/module/qca_nss_dp/parameters/dp_phy_auto_neg ] && echo 0 > /sys/module/qca_nss_dp/parameters/dp_phy_auto_neg 2>/dev/null || true
[ -w /sys/module/qca_nss_dp/parameters/dp_phy_reset_on_down ] && echo 0 > /sys/module/qca_nss_dp/parameters/dp_phy_reset_on_down 2>/dev/null || true
[ -w /sys/module/qca_nss_dp/parameters/dp_link_stable_time ] && echo 3 > /sys/module/qca_nss_dp/parameters/dp_link_stable_time 2>/dev/null || true
[ -w /sys/module/qca_nss_drv/parameters/nss_watchdog ] && echo 0 > /sys/module/qca_nss_drv/parameters/nss_watchdog 2>/dev/null || true
[ -w /sys/module/qca_nss_drv/parameters/pbuf_high_watermark ] && echo 10 > /sys/module/qca_nss_drv/parameters/pbuf_high_watermark 2>/dev/null || true
[ -w /sys/module/qca_nss_drv/parameters/multi_queue ] && echo 1 > /sys/module/qca_nss_drv/parameters/multi_queue 2>/dev/null || true
[ -w /sys/module/xt_FULLCONENAT/parameters/enable ] && echo 1 > /sys/module/xt_FULLCONENAT/parameters/enable 2>/dev/null || true
[ -w /sys/kernel/debug/nss/flow_preload/enable ] && echo 2 > /sys/kernel/debug/nss/flow_preload/enable 2>/dev/null || true
[ -c /dev/watchdog ] && echo 1 > /proc/sys/kernel/nmi_watchdog 2>/dev/null || true
EOF

chmod +x package/base-files/files/etc/uci-defaults/* 2>/dev/null || true

# ============================================
# 9. 守护进程 + 掉线自愈
# ============================================
green "====9 Guardian===="

cat > package/base-files/files/usr/bin/roc-guardian <<'GUARDIAN'
#!/bin/bash
LOG="/tmp/roc-guardian.log"; MAX=51200
log() {
    [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt "$MAX" ] && : > "$LOG"
    echo "$(date '+%F %T') $1" >> "$LOG"; logger -t "roc-guardian" "$1"
}
tcp_ok() {
    bash -c "echo >/dev/tcp/$1/$2" 2>/dev/null &
    local p=$!
    for i in 1 2 3 4; do kill -0 "$p" 2>/dev/null || { wait "$p" 2>/dev/null; return $?; }; sleep 0.5; done
    kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; return 1
}
g1() { while true; do
    for proc in dnsmasq uhttpd dropbear odhcpd zerotier-one; do pid=$(pgrep -f "$proc" 2>/dev/null | head -1); [ -n "$pid" ] && [ -w "/proc/$pid/oom_score_adj" ] && echo -500 > "/proc/$pid/oom_score_adj" 2>/dev/null; done
    m=$(awk '/^MemTotal/{t=$2}/^MemAvailable/{a=$2}END{printf "%.0f",(t-a)*100/t}' /proc/meminfo 2>/dev/null || echo 0)
    [ "$m" -gt 95 ] && { sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; log "CRITICAL: mem ${m}%"; }
    [ "$m" -gt 85 ] && [ "$m" -le 95 ] && { sync; echo 1 > /proc/sys/vm/drop_caches 2>/dev/null; log "WARN: mem ${m}%"; }
    sleep 300
done }
g2() { while true; do
    pgrep -f dnsmasq >/dev/null 2>&1 || { log "dnsmasq dead"; /etc/init.d/dnsmasq restart 2>/dev/null; }
    pgrep -f uhttpd >/dev/null 2>&1 || { log "uhttpd dead"; /etc/init.d/uhttpd restart 2>/dev/null; }
    pgrep -f odhcpd >/dev/null 2>&1 || { log "odhcpd dead"; /etc/init.d/odhcpd restart 2>/dev/null; }
    sleep 120
done }
g3() { while true; do
    uci -q get network.wan.proto 2>/dev/null | grep -q pppoe || { sleep 60; continue; }
    pgrep -f "pppd.*wan" >/dev/null 2>&1 || { log "pppd dead"; ifup wan 2>/dev/null; sleep 60; continue; }
    gw=$(ip route 2>/dev/null | awk '/default via/{print $3; exit}')
    [ -z "$gw" ] && { sleep 60; continue; }
    ping -c1 -W2 "$gw" >/dev/null 2>&1 && { sleep 60; continue; }
    ok=0; for p in 80 443; do tcp_ok "$gw" "$p" && { ok=1; break; }; done
    [ "$ok" -eq 0 ] && { log "gw $gw unreachable"; ifdown wan 2>/dev/null; sleep 5; ifup wan 2>/dev/null; }
    sleep 60
done }
g4() { while true; do
    [ -r /sys/kernel/debug/nss/stats ] && head -5 /sys/kernel/debug/nss/stats 2>/dev/null | grep -q "HANG\|crash" && {
        log "NSS hang"; /etc/init.d/qca-nss-drv restart 2>/dev/null; /etc/init.d/qca-nss-ecm restart 2>/dev/null
    }
    sleep 300
done }
log "Guardian v5.0"
while true; do
    g1 & p1=$!; g2 & p2=$!; g3 & p3=$!; g4 & p4=$!
    while kill -0 "$p1" 2>/dev/null && kill -0 "$p2" 2>/dev/null && kill -0 "$p3" 2>/dev/null && kill -0 "$p4" 2>/dev/null; do sleep 30; done
    log "Child died, restarting"; for p in $p1 $p2 $p3 $p4; do kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done
    sleep 5
done
GUARDIAN
chmod +x package/base-files/files/usr/bin/roc-guardian 2>/dev/null || true

cat > package/base-files/files/etc/init.d/roc-guardian <<'EOF'
#!/bin/sh /etc/rc.common
START=99; USE_PROCD=1; NAME=roc-guardian
start_service() { procd_set_param command /usr/bin/roc-guardian; procd_set_param respawn 3600 1 3600; }
EOF
chmod +x package/base-files/files/etc/init.d/roc-guardian 2>/dev/null || true

cat > package/base-files/files/etc/hotplug.d/iface/99-wan-recover <<'EOF'
#!/bin/sh
[ "$ACTION" = "ifup" ] && [ "${INTERFACE%%[0-9]*}" = "wan" ] || exit 0
sleep 5
[ -x /etc/init.d/qca-nss-ecm ] && /etc/init.d/qca-nss-ecm restart 2>/dev/null || true
[ -w /sys/kernel/debug/nss/flow_preload/enable ] && echo 2 > /sys/kernel/debug/nss/flow_preload/enable 2>/dev/null || true
[ "$(uci -q get network.wan.proto)" = "pppoe" ] && [ -d /sys/class/net/pppoe-wan ] && ip link set pppoe-wan mtu 1492 2>/dev/null || true
[ -f /tmp/resolv.conf.auto ] && /etc/init.d/dnsmasq reload 2>/dev/null || true
pgrep zerotier-one >/dev/null 2>&1 && { sleep 10; /etc/init.d/zerotier restart 2>/dev/null; }
[ -x /etc/init.d/odhcpd ] && /etc/init.d/odhcpd reload 2>/dev/null || true
EOF
chmod +x package/base-files/files/etc/hotplug.d/iface/99-wan-recover 2>/dev/null || true

# ============================================
# 10. 收尾
# ============================================
green "====10 Finalize===="
./scripts/feeds update -a 2>/dev/null || true
./scripts/feeds install -a 2>/dev/null || true

[ -f .config ] || touch .config
for key in \
    CONFIG_PACKAGE_kmod-qca-nss-drv-flow-preload \
    CONFIG_NSS_DRV_FLOW_PRELOAD_ENABLE; do
    sed -i "/^${key}[= ]/d; /^# ${key} is not set/d" .config 2>/dev/null || true
    grep -q "^${key}=y" .config 2>/dev/null || echo "${key}=y" >> .config
done

green "========================================="
green "  AX5 v9.5 Final Stable"
green "  设备: 红米 AX5 / AX5 JDCloud (512M)"
green "  Theme: Argon | IRQ: Auto"
green "  NSS-DP: PHY 禁止过度管理"
green "  PassWall: 科学上网"
green "  IPv4: PPPoE + FullCone NAT + BBR"
green "  IPv6: 完整支持 + 防火墙优化"
green "  Kernel: $KERNEL_VER (上游自动适配)"
green "  启动链: SSDK→NSS→网络→IPv6→服务"
green "========================================="
