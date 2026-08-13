#!/usr/bin/env bash
# ============================================================
# custom-patch.sh — 自动同步后应用的补丁脚本
# ============================================================
# 此脚本由 sync-and-patch.yml 工作流在合并上游代码后自动调用。
# 它会对以下三个文件应用自定义修改：
#   1. configs/General.config  — 插件开关 + 新增插件
#   2. configs/IPQ807X.config  — kmod-tun 内核支持
#   3. scripts/Roc-script.sh   — 移除 aurora 克隆、新增 serverchan/istore 克隆
#
# 设计原则：
#   - 幂等性：可重复运行，不会产生重复内容
#   - 健壮性：使用标记块（marker）确保旧补丁被清除后再重新插入
#   - 安全性：所有修改都有回退机制
# ============================================================

set -euo pipefail

echo "=========================================="
echo "  开始应用自定义补丁"
echo "=========================================="

# ------------------------------------------------------------
# 1. 修改 configs/General.config
# ------------------------------------------------------------
GC="configs/General.config"

if [ -f "$GC" ]; then
    echo "[1/3] 正在修改 $GC ..."

    # 1a. 移除旧的自定义块（幂等）
    sed -i '/^### === 自定义新增配置（开始）===/,/^### === 自定义新增配置（结束）===/d' "$GC"

    # 1b. 修改已有行：去掉不需要的插件（y → n）
    sed -i 's/^CONFIG_PACKAGE_luci-theme-aurora=y$/CONFIG_PACKAGE_luci-theme-aurora=n/' "$GC"
    sed -i 's/^CONFIG_PACKAGE_luci-app-aurora-config=y$/CONFIG_PACKAGE_luci-app-aurora-config=n/' "$GC"
    sed -i 's/^CONFIG_PACKAGE_luci-app-samba4=y$/CONFIG_PACKAGE_luci-app-samba4=n/' "$GC"
    sed -i 's/^CONFIG_PACKAGE_luci-app-hd-idle=y$/CONFIG_PACKAGE_luci-app-hd-idle=n/' "$GC"
    sed -i 's/^CONFIG_PACKAGE_luci-app-watchcat=y$/CONFIG_PACKAGE_luci-app-watchcat=n/' "$GC"

    # 1c. 修改已有行：启用 argon 主题（n → y）
    sed -i 's/^CONFIG_PACKAGE_luci-theme-argon=n$/CONFIG_PACKAGE_luci-theme-argon=y/' "$GC"
    sed -i 's/^CONFIG_PACKAGE_luci-app-argon-config=n$/CONFIG_PACKAGE_luci-app-argon-config=y/' "$GC"

    # 1d. 追加自定义新增配置块
    cat >> "$GC" << 'PATCH_EOF'

### === 自定义新增配置（开始）=== ###

# --- 1. 内核支持 kmod-tun（ZeroTier / EasyTier 等组网工具依赖）---
CONFIG_PACKAGE_kmod-tun=y

# --- 2. Argon 主题（源码由 Roc-script.sh 从 jerrykuku 仓库拉取最新版）---
CONFIG_PACKAGE_luci-theme-argon=y
CONFIG_PACKAGE_luci-app-argon-config=y

# --- 3. ServerChan（Server酱推送，源码由 Roc-script.sh 从 afala2020 仓库拉取）---
CONFIG_PACKAGE_luci-app-serverchan=y

# --- 4. DDNS-Go（ImmortalWrt feeds 自带）---
CONFIG_PACKAGE_luci-app-ddns-go=y
CONFIG_PACKAGE_ddns-go=y

# --- 5. ZeroTier（ImmortalWrt feeds 自带）---
CONFIG_PACKAGE_luci-app-zerotier=y
CONFIG_PACKAGE_zerotier=y

# --- 6. iStore 应用商店（包名 luci-app-store，源码由 Roc-script.sh 从 linkease/istore 拉取）---
CONFIG_PACKAGE_luci-app-store=y

# --- 7. 确保简体中文语言包编译 ---
CONFIG_LUCI_LANG_zh_Hans=y

### === 自定义新增配置（结束）=== ###
PATCH_EOF
    echo "  ✓ General.config 修改完成"
else
    echo "  ⚠ 未找到 $GC，跳过"
fi

# ------------------------------------------------------------
# 2. 修改 configs/IPQ807X.config
# ------------------------------------------------------------
IC="configs/IPQ807X.config"

if [ -f "$IC" ]; then
    echo "[2/3] 正在修改 $IC ..."

    # 2a. 将 kmod-tun 从 "not set" 改为 =y
    sed -i 's/^# CONFIG_PACKAGE_kmod-tun is not set$/CONFIG_PACKAGE_kmod-tun=y/' "$IC"

    # 2b. 如果文件中没有 kmod-tun 行（上游可能改了格式），追加一行
    if ! grep -q '^CONFIG_PACKAGE_kmod-tun=y$' "$IC"; then
        echo 'CONFIG_PACKAGE_kmod-tun=y' >> "$IC"
    fi

    echo "  ✓ IPQ807X.config 修改完成（kmod-tun=y）"
else
    echo "  ⚠ 未找到 $IC，跳过"
fi

# ------------------------------------------------------------
# 3. 修改 scripts/Roc-script.sh
# ------------------------------------------------------------
RS="scripts/Roc-script.sh"

if [ -f "$RS" ]; then
    echo "[3/3] 正在修改 $RS ..."

    # 3a. 删除 aurora 主题的 git clone 行
    sed -i '/git clone --depth=1 https:\/\/github.com\/eamonxg\/luci-theme-aurora/d' "$RS"
    sed -i '/git clone --depth=1 https:\/\/github.com\/eamonxg\/luci-app-aurora-config/d' "$RS"

    # 3b. 删除旧的自定义修改块（幂等）
    # 使用 awk 删除标记块之间的内容（包括标记行本身）
    awk '
    /^# === 自定义修改开始 ===/ { skip=1; next }
    /^# === 自定义修改结束 ===/ { skip=0; next }
    skip { next }
    { print }
    ' "$RS" > "${RS}.tmp" && mv "${RS}.tmp" "$RS"

    # 3c. 在 "./scripts/feeds update -i -a" 行之前插入自定义修改块
    # 使用 awk 在锚点行前插入内容
    awk '
    /^\.\/scripts\/feeds update -i -a$/ && !inserted {
        print "# === 自定义修改开始 ==="
        print "# 移除 aurora 主题相关文件（确保不打包进固件）"
        print "rm -rf feeds/luci/themes/luci-theme-aurora"
        print "rm -rf feeds/luci/applications/luci-app-aurora-config"
        print ""
        print "# ServerChan（Server酱推送通知）"
        print "# 原始仓库 tty228/luci-app-serverchan 已合并到 luci-app-wechatpush，此处使用 afala2020 的维护分支"
        print "git clone --depth=1 https://github.com/afala2020/luci-app-serverchan package/luci-app-serverchan"
        print ""
        print "# iStore 应用商店（包名 luci-app-store，依赖 luci-lib-taskd，均在 linkease/istore 仓库内）"
        print "git clone --depth=1 https://github.com/linkease/istore package/istore"
        print "# === 自定义修改结束 ==="
        print ""
        inserted=1
    }
    { print }
    ' "$RS" > "${RS}.tmp" && mv "${RS}.tmp" "$RS"

    echo "  ✓ Roc-script.sh 修改完成"
else
    echo "  ⚠ 未找到 $RS，跳过"
fi

# ------------------------------------------------------------
# 汇总
# ------------------------------------------------------------
echo ""
echo "=========================================="
echo "  自定义补丁应用完成"
echo "=========================================="
echo ""
echo "修改摘要："
echo "  - General.config: 去掉 aurora/samba4/hd-idle/watchcat，启用 argon，新增 kmod-tun/serverchan/ddns-go/zerotier/istore"
echo "  - IPQ807X.config: 添加 CONFIG_PACKAGE_kmod-tun=y"
echo "  - Roc-script.sh:  移除 aurora 克隆，新增 serverchan 和 istore 克隆"
echo ""
