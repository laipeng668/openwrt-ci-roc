#!/usr/bin/env bash
# ============================================================
# custom-patch 仅修复serverchan编译失败 + 锁定仅编译redmi_ax6_stock设备
# 文件路径完全适配当前仓库目录树，保留jool/openvswitch不删除不关闭
# 修复内容：新增arping、wrtbwmon依赖配置，解决插件编译报错
# 新增：锁定ipq807x仅编译redmi_ax6-stock，大幅减少编译产物与耗时
# ============================================================
set -Eeuo pipefail
echo "=========================================="
echo "  执行自定义补丁：修复serverchan + 锁定仅编译redmi_ax6_stock"
echo "=========================================="
# ---------------------- 1、处理 General.config 【路径正确】 ----------------------
GC="configs/General.config"
if [ -f "$GC" ]; then
    echo "[1/3] 处理 $GC"
    # 清空旧自定义块，保证幂等重复运行不重复追加
    sed -i '/^### === 自定义新增配置（开始）===/,/^### === 自定义新增配置（结束）===/d' "$GC"
    # 主题相关开关
    sed -i 's/^CONFIG_PACKAGE_luci-theme-aurora=y$/CONFIG_PACKAGE_luci-theme-aurora=n/' "$GC"
    sed -i 's/^CONFIG_PACKAGE_luci-app-aurora-config=y$/CONFIG_PACKAGE_luci-app-aurora-config=n/' "$GC"
    sed -i 's/^CONFIG_PACKAGE_luci-app-samba4=y$/CONFIG_PACKAGE_luci-app-samba4=n/' "$GC"
    sed -i 's/^CONFIG_PACKAGE_luci-app-hd-idle=y$/CONFIG_PACKAGE_luci-app-hd-idle=n/' "$GC"
    sed -i 's/^CONFIG_PACKAGE_luci-app-watchcat=y$/CONFIG_PACKAGE_luci-app-watchcat=n/' "$GC"
    sed -i 's/^CONFIG_PACKAGE_luci-theme-argon=n$/CONFIG_PACKAGE_luci-theme-argon=y/' "$GC"
    sed -i 's/^CONFIG_PACKAGE_luci-app-argon-config=n$/CONFIG_PACKAGE_luci-app-argon-config=y/' "$GC"
    # 写入配置块（重点：新增arping、wrtbwmon；不修改jool/openvswitch）
    cat >> "$GC" << 'PATCH_EOF'
### === 自定义新增配置（开始）===
# 内核TUN虚拟网卡（zerotier/组网依赖）
CONFIG_PACKAGE_kmod-tun=y
# Argon主题
CONFIG_PACKAGE_luci-theme-argon=y
CONFIG_PACKAGE_luci-app-argon-config=y
# ServerChan推送 + 强制依赖arping（修复编译崩溃核心）
CONFIG_PACKAGE_luci-app-serverchan=y
CONFIG_PACKAGE_arping=y
# WeChat推送配套依赖wrtbwmon
CONFIG_PACKAGE_luci-app-wechatpush=y
CONFIG_PACKAGE_wrtbwmon=y
# DDNS-Go动态域名
CONFIG_PACKAGE_luci-app-ddns-go=y
CONFIG_PACKAGE_ddns-go=y
# ZeroTier虚拟局域网
CONFIG_PACKAGE_luci-app-zerotier=y
CONFIG_PACKAGE_zerotier=y
# iStore应用商店
CONFIG_PACKAGE_luci-app-store=y
# 简体中文语言支持
CONFIG_LUCI_LANG_zh_Hans=y
### === 自定义新增配置（结束）===
PATCH_EOF
    echo "✅ $GC 完成，已添加arping/wrtbwmon，jool/openvswitch无修改"
else
    echo "⚠ 文件不存在：$GC，跳过"
fi
# ---------------------- 2、处理 IPQ807X.config 【修复缺失.config后缀bug + 锁定仅redmi_ax6_stock】 ----------------------
IC="configs/IPQ807X.config"
if [ -f "$IC" ]; then
    echo "[2/3] 处理 $IC"
    # 开启kmod-tun内核模块
    sed -i 's/^# CONFIG_PACKAGE_kmod-tun is not set$/CONFIG_PACKAGE_kmod-tun=y/' "$IC"
    grep -q '^CONFIG_PACKAGE_kmod-tun=y' "$IC" || echo 'CONFIG_PACKAGE_kmod-tun=y' >> "$IC"
    # 关键：补充arping、wrtbwmon，解决编译报错
    grep -q '^CONFIG_PACKAGE_arping=y' "$IC" || echo 'CONFIG_PACKAGE_arping=y' >> "$IC"
    grep -q '^CONFIG_PACKAGE_wrtbwmon=y' "$IC" || echo 'CONFIG_PACKAGE_wrtbwmon=y' >> "$IC"

    # ========== 新增：锁定仅编译 redmi_ax6_stock 设备 ==========
    echo "[2/3-1] 写入设备锁定配置至文件末尾，仅保留redmi_ax6_stock"
    # 先删除旧的设备锁定区块，防止重复叠加
    sed -i '/^### === 设备锁定：仅编译redmi_ax6_stock ===/,/^### === 设备锁定结束 ===/d' "$IC"
    # 在文件最底部追加设备黑白名单
    cat >> "$IC" << 'DEVICE_LOCK_EOF'

### === 设备锁定：仅编译redmi_ax6_stock ===
# 仅启用红米AX6 stock版本
CONFIG_TARGET_qualcommax_ipq807x_DEVICE_redmi_ax6_stock=y
# 禁用ipq807x平台下全部其他设备
CONFIG_TARGET_qualcommax_ipq807x_DEVICE_aliyun_ap8220=n
CONFIG_TARGET_qualcommax_ipq807x_DEVICE_arcadyan_aw1000=n
CONFIG_TARGET_qualcommax_ipq807x_DEVICE_asus_rt_ax89x=n
CONFIG_TARGET_qualcommax_ipq807x_DEVICE_buffalo_wxr_5950ax12=n
CONFIG_TARGET_qualcommax_ipq807x_DEVICE_cmcc_rm2_6=n
CONFIG_TARGET_qualcommax_ipq807x_DEVICE_compex_wpq873=n
CONFIG_TARGET_qualcommax_ipq807x_DEVICE_dlink_dl_wrx36=n
CONFIG_TARGET_qualcommax_ipq807x_DEVICE_edgecore_eap102=n
CONFIG_TARGET_qualcommax_ipq807x_DEVICE_edimax_cax1800=n
CONFIG_TARGET_qualcommax_ipq807x_DEVICE_meraki_mx64=n
CONFIG_TARGET_qualcommax_ipq807x_DEVICE_netgear_rax120=n
CONFIG_TARGET_qualcommax_ipq807x_DEVICE_qnap_qsw_m2108r=n
CONFIG_TARGET_qualcommax_ipq807x_DEVICE_redmi_ax6=n
CONFIG_TARGET_qualcommax_ipq807x_DEVICE_tplink_xdr6088=n
CONFIG_TARGET_qualcommax_ipq807x_DEVICE_xiaomi_ax3600=n
CONFIG_TARGET_qualcommax_ipq807x_DEVICE_xiaomi_ax9000=n
CONFIG_TARGET_qualcommax_ipq807x_DEVICE_zbt_z800ax=n
### === 设备锁定结束 ===
DEVICE_LOCK_EOF

    echo "✅ $IC 完成，新增arping/wrtbwmon + 锁定仅编译redmi_ax6_stock，保留jool/openvswitch配置"
else
    echo "⚠ 文件不存在：$IC，跳过"
fi
# ---------------------- 3、修改 scripts/Roc-script.sh 【路径正确】 ----------------------
RS="scripts/Roc-script.sh"
if [ -f "$RS" ]; then
    echo "[3/3] 处理 $RS"
    # 删除废弃aurora拉取命令
    sed -i '/git clone --depth=1 https:\/\/github.com\/eamonxg\/luci-theme-aurora/d' "$RS"
    sed -i '/git clone --depth=1 https:\/\/github.com\/eamonxg\/luci-app-aurora-config/d' "$RS"
    # 清空旧自定义区块
    awk '
    /^# === 自定义修改开始 ===/ { skip=1; next }
    /^# === 自定义修改结束 ===/ { skip=0; next }
    skip { next }
    { print }
    ' "$RS" > "${RS}.tmp" && mv "${RS}.tmp" "$RS"
    # 插入自定义拉取逻辑：**不删除jool/openvswitch任何文件**，仅拉取serverchan/istore
    awk '
    /^\.\/scripts\/feeds update -i -a$/ && !inserted {
        print "# === 自定义修改开始 ==="
        print "# 清理废弃Aurora残留目录"
        print "rm -rf feeds/luci/themes/luci-theme-argon feeds/luci/applications/luci-app-argon-config"
        print "# 拉取ServerChan推送插件"
        print "git clone --depth=1 https://github.com/afala2020/luci-app-serverchan package/luci-app-serverchan"
        print "# 拉取iStore应用商店"
        print "git clone --depth=1 https://github.com/linkease/istore package/istore"
        print "# === 自定义修改结束 ==="
        print ""
        inserted=1
    }
    { print }
    ' "$RS" > "${RS}.tmp" && mv "${RS}.tmp" "$RS"
    echo "✅ $RS 修改完成，未操作jool/openvswitch源码目录"
else
    echo "⚠ 文件不存在：$RS，跳过"
fi
echo ""
echo "====================补丁执行完毕===================="
echo "修复清单："
echo "1. 修正全部文件路径，适配当前仓库目录树，消除sed: no input files报错"
echo "2. General.config / IPQ807X.config 同步开启 arping 依赖，彻底解决 luci-app-serverchan 编译失败"
echo "3. 同步开启 wrtbwmon，消除wechatpush依赖警告"
echo "4. 完全保留 jool、openvswitch 包：不删除源码、不关闭配置，原有警告正常输出"
echo "5. 保留Argon/ZeroTier/DDNS-Go/iStore全部预装插件"
echo "6. 新增设备锁定：ipq807x平台仅编译redmi_ax6_stock，减少大量编译耗时与固件产物"
echo "======================================================"
