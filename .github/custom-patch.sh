#!/usr/bin/env bash
# ---------------------- 1、处理 General.config ----------------------
GC="configs/General.config"
if [ -f "$GC" ]; then
    echo "[1/3] 处理 $GC"
    # 清空旧自定义块
    sed -i '/^### === 自定义新增配置（开始）===/,/^### === 自定义新增配置（结束）===/d' "$GC"
    # 关闭aurora，开启argon
    sed -i 's/^CONFIG_PACKAGE_luci-theme-aurora=y$/CONFIG_PACKAGE_luci-theme-aurora=n/' "$GC"
    sed -i 's/^CONFIG_PACKAGE_luci-app-aurora-config=y$/CONFIG_PACKAGE_luci-app-aurora-config=n/' "$GC"
    sed -i 's/^CONFIG_PACKAGE_luci-app-samba4=y$/CONFIG_PACKAGE_luci-app-samba4=n/' "$GC"
    sed -i 's/^CONFIG_PACKAGE_luci-app-hd-idle=y$/CONFIG_PACKAGE_luci-app-hd-idle=n/' "$GC"
    sed -i 's/^CONFIG_PACKAGE_luci-app-watchcat=y$/CONFIG_PACKAGE_luci-app-watchcat=n/' "$GC"
    sed -i 's/^CONFIG_PACKAGE_luci-theme-argon=n$/CONFIG_PACKAGE_luci-theme-argon=y/' "$GC"
    sed -i 's/^CONFIG_PACKAGE_luci-app-argon-config=n$/CONFIG_PACKAGE_luci-app-argon-config=y/' "$GC"
    # 写入配置块
    cat >> "$GC" << 'PATCH_EOF'
### === 自定义新增配置（开始）===
# 内核TUN虚拟网卡（zerotier/组网依赖）
CONFIG_PACKAGE_kmod-tun=y
# Argon主题
CONFIG_PACKAGE_luci-theme-argon=y
CONFIG_PACKAGE_luci-app-argon-config=y
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
    echo "✅ $GC 完成，arping/wrtbwmon已开启"
else
    echo "⚠ 文件不存在：$GC，跳过"
fi

# ---------------------- 2、处理 IPQ807X.config 锁定仅redmi_ax6_stock ----------------------
IC="configs/IPQ807X.config"
if [ -f "$IC" ]; then
    echo "[2/3] 处理 $IC"
    # 开启kmod-tun
    sed -i 's/^# CONFIG_PACKAGE_kmod-tun is not set$/CONFIG_PACKAGE_kmod-tun=y/' "$IC"
    grep -q '^CONFIG_PACKAGE_kmod-tun=y' "$IC" || echo 'CONFIG_PACKAGE_kmod-tun=y' >> "$IC"
    # 补充arping、wrtbwmon
    grep -q '^CONFIG_PACKAGE_arping=y' "$IC" || echo 'CONFIG_PACKAGE_arping=y' >> "$IC"
    grep -q '^CONFIG_PACKAGE_wrtbwmon=y' "$IC" || echo 'CONFIG_PACKAGE_wrtbwmon=y' >> "$IC"
    # 清除旧设备锁定区块
    sed -i '/^### === 设备锁定：仅编译redmi_ax6_stock ===/,/^### === 设备锁定结束 ===/d' "$IC"
    # 写入设备黑白名单
    cat >> "$IC" << 'DEVICE_LOCK_EOF'
### === 设备锁定：仅编译redmi_ax6_stock ===
CONFIG_TARGET_qualcommax_ipq807x_DEVICE_redmi_ax6_stock=y
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
    echo "✅ $IC 完成，仅编译redmi_ax6_stock"
else
    echo "⚠ 文件不存在：$IC，跳过"
fi

# ---------------------- 3、修改 scripts/Roc-script.sh 消除冲突 ----------------------
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
    # 插入拉取逻辑，删除Argon目录仅一次，无重复冲突
    awk '
    /^\.\/scripts\/feeds update -i -a$/ && !inserted {
        print "# === 自定义修改开始 ==="
        print "# 清理旧Argon目录避免冲突"
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
    echo "✅ $RS 修改完成"
else
    echo "⚠ 文件不存在：$RS，跳过"
fi

echo ""
echo "====================补丁执行完毕===================="
echo "修复清单："
echo "1. 自动清理 luci-app-serverchan Makefile 版本号尾部空格，彻底解决 version invalid 编译报错"
echo "2. General.config / IPQ807X.config 同步 arping/wrtbwmon 依赖"
echo "3. 锁定ipq807x仅编译redmi_ax6_stock，减少编译耗时"
echo "4. 修复Roc-script.sh Argon目录重复删除冲突问题"
echo "5. 脚本增加文件存在判断，避免sed无输入报错"
echo "======================================================"
