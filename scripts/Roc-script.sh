# 修改默认IP & 固件名称 & 编译署名
sed -i 's/192.168.1.1/192.168.2.1/g' package/base-files/files/bin/config_generate
sed -i "s/hostname='.*'/hostname='Roc'/g" package/base-files/files/bin/config_generate
sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ Build by Roc')/g" feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js

# 修正使用ccache编译vlmcsd的问题
mkdir -p feeds/packages/net/vlmcsd/patches
cp -f $GITHUB_WORKSPACE/patches/fix_vlmcsd_compile_with_ccache.patch feeds/packages/net/vlmcsd/patches

# 移除要替换的包
rm -rf feeds/packages/net/alist
rm -rf feeds/luci/applications/luci-app-alist
rm -rf feeds/packages/net/open-app-filter
rm -rf package/emortal/luci-app-athena-led

# Git稀疏克隆，只克隆指定目录到本地
function git_sparse_clone() {
  branch="$1" repourl="$2" && shift 2
  git clone --depth=1 -b $branch --single-branch --filter=blob:none --sparse $repourl
  repodir=$(echo $repourl | awk -F '/' '{print $(NF)}')
  cd $repodir && git sparse-checkout set $@
  mv -f $@ ../package
  cd .. && rm -rf $repodir
}

# AList & AdGuardHome & WolPlus & Lucky & OpenAppFilter & 集客无线AC控制器 & 雅典娜LED控制
git clone --depth=1 https://github.com/sbwml/luci-app-alist package/luci-app-alist
git_sparse_clone master https://github.com/kenzok8/openwrt-packages luci-app-adguardhome
git_sparse_clone main https://github.com/VIKINGYFY/packages luci-app-wolplus
git clone --depth=1 https://github.com/gdy666/luci-app-lucky package/luci-app-lucky
git clone --depth=1 https://github.com/destan19/OpenAppFilter.git package/OpenAppFilter
git clone --depth=1 https://github.com/lwb1978/openwrt-gecoosac package/openwrt-gecoosac
git clone --depth=1 https://github.com/NONGFAH/luci-app-athena-led package/luci-app-athena-led
chmod +x package/luci-app-athena-led/root/etc/init.d/athena_led package/luci-app-athena-led/root/usr/sbin/athena-led

./scripts/feeds update -a
./scripts/feeds install -a
