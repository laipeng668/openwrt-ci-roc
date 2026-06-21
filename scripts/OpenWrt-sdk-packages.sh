#!/usr/bin/env bash
set -Eeuo pipefail

PACKAGES_REPO="${PACKAGES_REPO:-https://github.com/laipeng668/packages}"
LUCI_REPO="${LUCI_REPO:-https://github.com/laipeng668/luci}"
GECOOSAC_REPO="${GECOOSAC_REPO:-https://github.com/laipeng668/luci-app-gecoosac}"
OPENWRT_TARGET="${OPENWRT_TARGET:-x86}"
OPENWRT_SUBTARGET="${OPENWRT_SUBTARGET:-64}"
OPENWRT_SDK_BASE_URL="${OPENWRT_SDK_BASE_URL:-https://downloads.openwrt.org/snapshots/targets/$OPENWRT_TARGET/$OPENWRT_SUBTARGET}"
SDK_URL="${SDK_URL:-}"
PACKAGE_CONFIG_FILES="${PACKAGE_CONFIG_FILES:-${CONFIG_FILES:-configs/x86-64.config configs/Packages.config}}"
unset CONFIG_FILES
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
SDK_ROOT="${SDK_ROOT:-$RUNNER_TEMP/openwrt-sdk}"
OUTPUT_DIR="${OUTPUT_DIR:-${GITHUB_WORKSPACE:-$PWD}/artifacts/packages}"
PACKAGE_ARCH_NAME="${PACKAGE_ARCH_NAME:-$OPENWRT_TARGET-$OPENWRT_SUBTARGET}"
PACKAGE_SELECTION="${PACKAGE_SELECTION:-${PACKAGE_NAME:-all}}"
SDK_ARCHIVE="$RUNNER_TEMP/openwrt-sdk.tarball"
SPARSE_ROOT="$RUNNER_TEMP/openwrt-sparse-clone"
WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"

COMPILE_TARGETS=()
CONFIG_FILE_LIST=()

log() {
  printf '\n==> %s\n' "$*" >&2
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

normalize_package_selection() {
  local selection="${1:-all}"

  selection="${selection,,}"
  case "$selection" in
    "" | all | "全部")
      printf 'all\n'
      ;;
    aria2 | ariang | frp | nginx | gecoosac | luci-app-aria2 | luci-app-frpc | luci-app-frps | luci-app-gecoosac)
      printf '%s\n' "$selection"
      ;;
    frpc | frps | frp-binary-toml | frp-toml)
      printf 'frp\n'
      ;;
    nginx-full | nginx-ssl)
      printf 'nginx\n'
      ;;
    *)
      die "Unsupported PACKAGE_SELECTION: ${1:-} (supported: all, aria2, ariang, frp, nginx, gecoosac, luci-app-aria2, luci-app-frpc, luci-app-frps, luci-app-gecoosac)"
      ;;
  esac
}

selection_matches() {
  local package_name

  [ "$PACKAGE_SELECTION" = all ] && return 0

  for package_name in "$@"; do
    [ "$PACKAGE_SELECTION" != "$package_name" ] || return 0
  done

  return 1
}

resolve_sdk_url() {
  local sdk_href

  if [ -n "$SDK_URL" ]; then
    printf '%s\n' "$SDK_URL"
    return
  fi

  log "Resolve OpenWrt main snapshot SDK"
  sdk_href="$(
    curl -fsSL "${OPENWRT_SDK_BASE_URL%/}/" |
      grep -oE 'href="[^"]*openwrt-sdk-[^"]+\.tar\.(xz|zst|gz)"' |
      sed -E 's/^href="([^"]+)"/\1/' |
      head -n 1 || true
  )"

  [ -n "$sdk_href" ] || die "OpenWrt SDK archive was not found at $OPENWRT_SDK_BASE_URL"

  case "$sdk_href" in
    http://* | https://*)
      printf '%s\n' "$sdk_href"
      ;;
    /*)
      printf 'https://downloads.openwrt.org%s\n' "$sdk_href"
      ;;
    *)
      printf '%s/%s\n' "${OPENWRT_SDK_BASE_URL%/}" "$sdk_href"
      ;;
  esac
}

download_sdk() {
  local resolved_url="$1"

  case "$resolved_url" in
    file://*)
      cp "${resolved_url#file://}" "$SDK_ARCHIVE"
      ;;
    /*)
      cp "$resolved_url" "$SDK_ARCHIVE"
      ;;
    *)
      curl -fsSL --retry 3 "$resolved_url" -o "$SDK_ARCHIVE"
      ;;
  esac
}

extract_sdk() {
  local resolved_url="$1"
  local archive_name
  archive_name="${resolved_url%%\?*}"

  mkdir -p "$SDK_ROOT"
  case "$archive_name" in
    *.tar.zst | *.tzst)
      tar --zstd -xf "$SDK_ARCHIVE" --strip-components=1 -C "$SDK_ROOT"
      ;;
    *.tar.xz | *.txz)
      tar -xJf "$SDK_ARCHIVE" --strip-components=1 -C "$SDK_ROOT"
      ;;
    *.tar.gz | *.tgz)
      tar -xzf "$SDK_ARCHIVE" --strip-components=1 -C "$SDK_ROOT"
      ;;
    *)
      tar -xf "$SDK_ARCHIVE" --strip-components=1 -C "$SDK_ROOT"
      ;;
  esac
}

git_sparse_clone() {
  local branch="$1"
  local repourl="$2"
  local repodir
  local sparse_path
  shift 2

  repodir="$SPARSE_ROOT/$(basename "${repourl%.git}")-${branch//\//-}"
  rm -rf "$repodir"
  git clone \
    --depth=1 \
    --no-tags \
    -b "$branch" \
    --single-branch \
    --filter=blob:none \
    --sparse \
    "$repourl" \
    "$repodir"

  (
    cd "$repodir"
    git sparse-checkout set "$@"
  )

  for sparse_path in "$@"; do
    local source_path="$repodir/$sparse_path"
    local package_name
    local target_path

    package_name="$(basename "$sparse_path")"
    target_path="$SDK_ROOT/package/roc/$package_name"

    [ -d "$source_path" ] || die "Sparse package directory not found: $source_path"
    [ -f "$source_path/Makefile" ] || die "Package Makefile not found: $source_path/Makefile"

    rm -rf "$target_path"
    mkdir -p "$(dirname "$target_path")"
    cp -a "$source_path" "$target_path"
  done

  rm -rf "$repodir"
}

remove_builtin_packages() {
  rm -rf \
    "$SDK_ROOT/feeds/packages/net/aria2" \
    "$SDK_ROOT/feeds/packages/net/ariang" \
    "$SDK_ROOT/feeds/packages/net/frp" \
    "$SDK_ROOT/feeds/packages/net/nginx" \
    "$SDK_ROOT/feeds/packages/net/gecoosac" \
    "$SDK_ROOT/feeds/luci/applications/luci-app-frpc" \
    "$SDK_ROOT/feeds/luci/applications/luci-app-frps" \
    "$SDK_ROOT/feeds/luci/applications/luci-app-gecoosac" \
    "$SDK_ROOT/package/feeds/packages/aria2" \
    "$SDK_ROOT/package/feeds/packages/ariang" \
    "$SDK_ROOT/package/feeds/packages/frp" \
    "$SDK_ROOT/package/feeds/packages/nginx" \
    "$SDK_ROOT/package/feeds/packages/gecoosac" \
    "$SDK_ROOT/package/feeds/luci/luci-app-frpc" \
    "$SDK_ROOT/package/feeds/luci/luci-app-frps" \
    "$SDK_ROOT/package/feeds/luci/luci-app-gecoosac"
}

load_custom_packages() {
  mkdir -p "$SPARSE_ROOT"

  git_sparse_clone aria2 "$PACKAGES_REPO" net/aria2
  git_sparse_clone ariang "$PACKAGES_REPO" net/ariang
  git_sparse_clone frp-binary-toml "$PACKAGES_REPO" net/frp
  git_sparse_clone nginx "$PACKAGES_REPO" net/nginx
  git_sparse_clone frp-toml "$LUCI_REPO" \
    applications/luci-app-frpc \
    applications/luci-app-frps
  git_sparse_clone main "$GECOOSAC_REPO" \
    gecoosac \
    luci-app-gecoosac
}

normalize_config_files() {
  printf '%s\n' "$PACKAGE_CONFIG_FILES" |
    sed -e 's/\r$//' -e 's/#.*$//' |
    tr ',[:space:]' '\n' |
    sed -e '/^$/d'
}

load_config_files() {
  local config_file
  local source_file

  : > "$SDK_ROOT/.config"
  mapfile -t CONFIG_FILE_LIST < <(normalize_config_files)

  [ "${#CONFIG_FILE_LIST[@]}" -gt 0 ] || die "PACKAGE_CONFIG_FILES did not contain any config file"

  for config_file in "${CONFIG_FILE_LIST[@]}"; do
    if [ -f "$config_file" ]; then
      source_file="$config_file"
    else
      source_file="$WORKSPACE/$config_file"
    fi

    [ -f "$source_file" ] || die "Config file not found: $config_file"
    cat "$source_file" >> "$SDK_ROOT/.config"
    printf '\n' >> "$SDK_ROOT/.config"
  done
}

config_package_enabled() {
  local package_name="$1"
  grep -Eq "^CONFIG_PACKAGE_${package_name}=(y|m)$" "$SDK_ROOT/.config"
}

config_package_prefix_enabled() {
  local package_prefix="$1"
  grep -Eq "^CONFIG_PACKAGE_${package_prefix}[^=]*=(y|m)$" "$SDK_ROOT/.config"
}

config_value() {
  local key="$1"

  sed -n -E "s/^${key}=\"?([^\"]*)\"?$/\1/p" "$SDK_ROOT/.config" | head -n 1
}

preload_gecoosac_binary() {
  local package_makefile="$SDK_ROOT/package/roc/gecoosac/Makefile"
  local package_version
  local target_arch
  local arch_packages
  local binary_name
  local binary_url
  local release_repo_url
  local source_file

  selection_matches gecoosac luci-app-gecoosac || return 0
  if ! config_package_enabled gecoosac && ! config_package_enabled luci-app-gecoosac; then
    return 0
  fi

  [ -f "$package_makefile" ] || die "gecoosac package Makefile not found: $package_makefile"

  package_version="$(sed -n 's/^PKG_VERSION:=//p' "$package_makefile" | head -n 1)"
  target_arch="$(config_value CONFIG_TARGET_ARCH)"
  arch_packages="$(config_value CONFIG_TARGET_ARCH_PACKAGES)"

  [ -n "$package_version" ] || die "gecoosac PKG_VERSION was not found"
  [ -n "$target_arch" ] || die "CONFIG_TARGET_ARCH was not found after defconfig"
  [ -n "$arch_packages" ] || die "CONFIG_TARGET_ARCH_PACKAGES was not found after defconfig"

  case "$target_arch" in
    aarch64)
      binary_name="ac_linux_arm64"
      ;;
    x86_64)
      binary_name="ac_linux_amd64"
      ;;
    *)
      die "Unsupported gecoosac target architecture: $target_arch (supported: x86_64, aarch64)"
      ;;
  esac

  mkdir -p "$SDK_ROOT/dl"
  source_file="$SDK_ROOT/dl/gecoosac-${package_version}-${arch_packages}"
  release_repo_url="${GECOOSAC_REPO%.git}"
  binary_url="${release_repo_url%/}/releases/download/V${package_version}/${binary_name}"

  if [ -s "$source_file" ]; then
    log "gecoosac binary already exists: $(basename "$source_file")"
    return 0
  fi

  log "Download gecoosac binary: $binary_name"
  curl -fL --retry 3 "$binary_url" -o "${source_file}.tmp"
  mv "${source_file}.tmp" "$source_file"
}

add_compile_target() {
  local compile_target="$1"
  local existing_target

  for existing_target in "${COMPILE_TARGETS[@]}"; do
    [ "$existing_target" != "$compile_target" ] || return
  done

  COMPILE_TARGETS+=("$compile_target")
}

generate_compile_targets() {
  COMPILE_TARGETS=()

  if selection_matches aria2 ariang luci-app-aria2 && {
    config_package_enabled aria2 ||
    config_package_enabled ariang ||
      config_package_enabled luci-app-aria2
  }; then
    add_compile_target package/roc/aria2/compile
  fi

  if selection_matches ariang && {
    config_package_enabled ariang ||
      config_package_enabled ariang-nginx
  }; then
    add_compile_target package/roc/ariang/compile
  fi

  if selection_matches frp luci-app-frpc luci-app-frps && {
    config_package_enabled frpc ||
    config_package_enabled frps ||
    config_package_enabled luci-app-frpc ||
      config_package_enabled luci-app-frps
  }; then
    add_compile_target package/roc/frp/compile
  fi

  if selection_matches nginx && {
    config_package_enabled nginx ||
    config_package_enabled nginx-full ||
    config_package_enabled nginx-ssl ||
      config_package_prefix_enabled nginx-mod-
  }; then
    add_compile_target package/roc/nginx/compile
  fi

  if selection_matches frp luci-app-frpc && config_package_enabled luci-app-frpc; then
    add_compile_target package/roc/luci-app-frpc/compile
  fi

  if selection_matches frp luci-app-frps && config_package_enabled luci-app-frps; then
    add_compile_target package/roc/luci-app-frps/compile
  fi

  if selection_matches aria2 luci-app-aria2 && config_package_enabled luci-app-aria2 && [ -d "$SDK_ROOT/package/feeds/luci/luci-app-aria2" ]; then
    add_compile_target package/feeds/luci/luci-app-aria2/compile
  fi

  if selection_matches gecoosac luci-app-gecoosac && {
    config_package_enabled gecoosac ||
      config_package_enabled luci-app-gecoosac
  }; then
    add_compile_target package/roc/gecoosac/compile
  fi

  if selection_matches gecoosac luci-app-gecoosac && config_package_enabled luci-app-gecoosac; then
    add_compile_target package/roc/luci-app-gecoosac/compile
  fi

  [ "${#COMPILE_TARGETS[@]}" -gt 0 ] || die "No matching package compile targets were enabled by $PACKAGE_CONFIG_FILES for PACKAGE_SELECTION=$PACKAGE_SELECTION"
}

copy_artifacts() {
  local package_bin_dir="$SDK_ROOT/bin/packages"
  local copied_count=0
  local package_file
  local package_name
  local target_file

  if [ ! -d "$package_bin_dir" ]; then
    die "SDK package output directory was not created: $package_bin_dir"
  fi

  if [ -z "$(find "$package_bin_dir" -type f \( -name '*.ipk' -o -name '*.apk' \) -print -quit)" ]; then
    die "No compiled .ipk or .apk files were found under $package_bin_dir"
  fi

  rm -rf "$OUTPUT_DIR"
  mkdir -p "$OUTPUT_DIR"
  while IFS= read -r -d '' package_file; do
    package_name="$(basename "$package_file")"
    target_file="$OUTPUT_DIR/$PACKAGE_ARCH_NAME-$package_name"
    [ ! -e "$target_file" ] || die "Duplicate package artifact name: $target_file"
    cp -a "$package_file" "$target_file"
    copied_count=$((copied_count + 1))
  done < <(find "$package_bin_dir" -type f \( -name '*.ipk' -o -name '*.apk' \) -print0)

  [ "$copied_count" -gt 0 ] || die "No package files were copied from $package_bin_dir"
  log "Copied $copied_count package files to $OUTPUT_DIR with prefix $PACKAGE_ARCH_NAME-"

  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "PACKAGE_OUTPUT_DIR=$OUTPUT_DIR" >> "$GITHUB_ENV"
    echo "RESOLVED_SDK_URL=$RESOLVED_SDK_URL" >> "$GITHUB_ENV"
  fi
}

PACKAGE_SELECTION="$(normalize_package_selection "$PACKAGE_SELECTION")"

log "Download OpenWrt SDK"
log "Selected package group: $PACKAGE_SELECTION"
RESOLVED_SDK_URL="$(resolve_sdk_url)"
rm -rf "$SDK_ROOT"
mkdir -p "$RUNNER_TEMP"
download_sdk "$RESOLVED_SDK_URL"
extract_sdk "$RESOLVED_SDK_URL"
[ -x "$SDK_ROOT/scripts/feeds" ] || die "Invalid SDK archive: scripts/feeds was not found"
[ -f "$SDK_ROOT/Makefile" ] || die "Invalid SDK archive: Makefile was not found"

log "Update SDK feeds"
cd "$SDK_ROOT"
./scripts/feeds update -a
./scripts/feeds install -a

log "Load custom packages"
remove_builtin_packages
load_custom_packages

log "Load package config"
load_config_files
make defconfig
preload_gecoosac_binary
generate_compile_targets

log "Compile packages"
for compile_target in "${COMPILE_TARGETS[@]}"; do
  make -j"$(nproc)" "$compile_target" || make -j1 "$compile_target" V=s
done

log "Collect package artifacts"
copy_artifacts
