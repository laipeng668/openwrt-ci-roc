#!/usr/bin/env bash
set -Eeuo pipefail

PACKAGES_REPO="${PACKAGES_REPO:-https://github.com/laipeng668/packages}"
LUCI_REPO="${LUCI_REPO:-https://github.com/laipeng668/luci}"
GECOOSAC_REPO="${GECOOSAC_REPO:-https://github.com/laipeng668/luci-app-gecoosac}"
ARGON_REPO="${ARGON_REPO:-https://github.com/jerrykuku/luci-theme-argon}"
ARGON_CONFIG_REPO="${ARGON_CONFIG_REPO:-https://github.com/jerrykuku/luci-app-argon-config}"
AURORA_REPO="${AURORA_REPO:-https://github.com/eamonxg/luci-theme-aurora}"
AURORA_CONFIG_REPO="${AURORA_CONFIG_REPO:-https://github.com/eamonxg/luci-app-aurora-config}"
OPENLIST2_REPO="${OPENLIST2_REPO:-https://github.com/laipeng668/luci-app-openlist2}"
LUCKY_REPO="${LUCKY_REPO:-https://github.com/gdy666/luci-app-lucky}"
OPENWRT_TARGET="${OPENWRT_TARGET:-x86}"
OPENWRT_SUBTARGET="${OPENWRT_SUBTARGET:-64}"
OPENWRT_TARGET_PROFILE="${OPENWRT_TARGET_PROFILE:-}"
OPENWRT_DOWNLOADS_BASE_URL="${OPENWRT_DOWNLOADS_BASE_URL:-https://downloads.openwrt.org}"
OPENWRT_SDK_VERSION="${OPENWRT_SDK_VERSION:-${SDK_VERSION:-main}}"
OPENWRT_SDK_BASE_URL="${OPENWRT_SDK_BASE_URL:-}"
SDK_URL="${SDK_URL:-}"
PACKAGE_CONFIG_FILES="${PACKAGE_CONFIG_FILES:-${CONFIG_FILES:-configs/x86-64.config configs/Packages.config}}"
unset CONFIG_FILES
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
SDK_ROOT="${SDK_ROOT:-$RUNNER_TEMP/openwrt-sdk}"
OUTPUT_DIR="${OUTPUT_DIR:-${GITHUB_WORKSPACE:-$PWD}/artifacts/packages}"
PACKAGE_ARCH_NAME="${PACKAGE_ARCH_NAME:-$OPENWRT_TARGET-$OPENWRT_SUBTARGET}"
PACKAGE_SELECTED_ARCH="${PACKAGE_SELECTED_ARCH:-$PACKAGE_ARCH_NAME}"
PACKAGE_SELECTION="${PACKAGE_SELECTION:-${PACKAGE_NAME:-all}}"
SDK_ARCHIVE="$RUNNER_TEMP/openwrt-sdk.tarball"
SPARSE_ROOT="$RUNNER_TEMP/openwrt-sparse-clone"
WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"

COMPILE_TARGETS=()
CONFIG_FILE_LIST=()
ARTIFACT_PACKAGE_NAMES=()

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
    frp | nginx | luci-app-aria2 | luci-app-frpc | luci-app-frps | luci-app-gecoosac | luci-app-lucky | luci-app-openlist2 | luci-theme-argon | luci-theme-aurora)
      printf '%s\n' "$selection"
      ;;
    aria2 | ariang)
      printf 'luci-app-aria2\n'
      ;;
    frpc)
      printf 'luci-app-frpc\n'
      ;;
    frps)
      printf 'luci-app-frps\n'
      ;;
    nginx-full | nginx-ssl)
      printf 'nginx\n'
      ;;
    gecoosac)
      printf 'luci-app-gecoosac\n'
      ;;
    openlist | openlist2)
      printf 'luci-app-openlist2\n'
      ;;
    luci-app-openlist)
      printf 'luci-app-openlist2\n'
      ;;
    lucky)
      printf 'luci-app-lucky\n'
      ;;
    *)
      die "Unsupported PACKAGE_SELECTION: ${1:-} (supported: all, nginx, luci-app-aria2, luci-app-frpc, luci-app-frps, luci-app-gecoosac, luci-app-lucky, luci-app-openlist2, luci-theme-argon, luci-theme-aurora; legacy aliases: aria2, ariang, frp, gecoosac, lucky, openlist2)"
      ;;
  esac
}

normalize_sdk_version() {
  local version="${1:-main}"

  version="${version,,}"
  case "$version" in
    "" | main | snapshot | snapshots | master)
      printf 'main\n'
      ;;
    23.05 | 24.10 | 25.12)
      printf '%s\n' "$version"
      ;;
    *)
      die "Unsupported OPENWRT_SDK_VERSION: ${1:-} (supported: main, 23.05, 24.10, 25.12)"
      ;;
  esac
}

load_inline_target_profile() {
  local profile="${1:-}"

  [ -n "$profile" ] || return 0

  case "$profile" in
    rax3000m | cmcc-rax3000m | cmcc_rax3000m)
      [ "$OPENWRT_TARGET" = mediatek ] && [ "$OPENWRT_SUBTARGET" = filogic ] ||
        die "OPENWRT_TARGET_PROFILE=$profile requires OPENWRT_TARGET=mediatek and OPENWRT_SUBTARGET=filogic"
      cat >> "$SDK_ROOT/.config" <<'EOF'
CONFIG_TARGET_mediatek=y
CONFIG_TARGET_mediatek_filogic=y
CONFIG_TARGET_mediatek_filogic_DEVICE_cmcc_rax3000m=y
EOF
      ;;
    *)
      die "Unsupported OPENWRT_TARGET_PROFILE: $profile (supported: rax3000m)"
      ;;
  esac
}

selection_is_all() {
  [ "$PACKAGE_SELECTION" = all ]
}

selection_is() {
  [ "$PACKAGE_SELECTION" = "$1" ]
}

selection_in() {
  local package_name

  selection_is_all && return 0

  for package_name in "$@"; do
    selection_is "$package_name" && return 0
  done

  return 1
}

resolve_sdk_url() {
  local sdk_base_url
  local sdk_href

  if [ -n "$SDK_URL" ]; then
    printf '%s\n' "$SDK_URL"
    return
  fi

  sdk_base_url="$(resolve_sdk_base_url)"
  log "Resolve OpenWrt $OPENWRT_SDK_VERSION SDK for $OPENWRT_TARGET/$OPENWRT_SUBTARGET"
  sdk_href="$(
    curl -fsSL "${sdk_base_url%/}/" |
      grep -oE 'href="[^"]*openwrt-sdk-[^"]+\.tar\.(xz|zst|gz)"' |
      sed -E 's/^href="([^"]+)"/\1/' |
      head -n 1 || true
  )"

  [ -n "$sdk_href" ] || die "OpenWrt SDK archive was not found at $sdk_base_url"

  case "$sdk_href" in
    http://* | https://*)
      printf '%s\n' "$sdk_href"
      ;;
    /*)
      printf '%s%s\n' "${OPENWRT_DOWNLOADS_BASE_URL%/}" "$sdk_href"
      ;;
    *)
      printf '%s/%s\n' "${sdk_base_url%/}" "$sdk_href"
      ;;
  esac
}

resolve_sdk_base_url() {
  local release_version
  local sdk_version

  if [ -n "$OPENWRT_SDK_BASE_URL" ]; then
    printf '%s\n' "$OPENWRT_SDK_BASE_URL"
    return
  fi

  sdk_version="$(normalize_sdk_version "$OPENWRT_SDK_VERSION")"
  if [ "$sdk_version" = main ]; then
    printf '%s/snapshots/targets/%s/%s\n' "${OPENWRT_DOWNLOADS_BASE_URL%/}" "$OPENWRT_TARGET" "$OPENWRT_SUBTARGET"
    return
  fi

  release_version="$(resolve_latest_release_version "$sdk_version")"
  printf '%s/releases/%s/targets/%s/%s\n' "${OPENWRT_DOWNLOADS_BASE_URL%/}" "$release_version" "$OPENWRT_TARGET" "$OPENWRT_SUBTARGET"
}

resolve_latest_release_version() {
  local release_version
  local series="$1"

  release_version="$(
    curl -fsSL "${OPENWRT_DOWNLOADS_BASE_URL%/}/releases/" |
      grep -oE 'href="[0-9]+\.[0-9]+(\.[0-9]+)?/"' |
      sed -E 's/^href="([^"]+)\/"/\1/' |
      grep -E "^${series//./\\.}(\\.[0-9]+)?$" |
      sort -V |
      tail -n 1 || true
  )"

  [ -n "$release_version" ] || die "OpenWrt release series was not found: $series"
  printf '%s\n' "$release_version"
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
  local target_root="$3"
  local repodir
  local sparse_path
  shift 3

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
    local target_path

    target_path="$SDK_ROOT/$target_root/$sparse_path"

    [ -d "$source_path" ] || die "Sparse package directory not found: $source_path"
    if [ ! -f "$source_path/Makefile" ] &&
      [ -z "$(find "$source_path" -mindepth 2 -maxdepth 2 -type f -name Makefile -print -quit)" ]; then
      die "Package Makefile not found under: $source_path"
    fi

    rm -rf "$target_path"
    mkdir -p "$(dirname "$target_path")"
    cp -a "$source_path" "$target_path"
  done

  rm -rf "$repodir"
}

git_clone_package_repo() {
  local repourl="$1"
  local target_path="$2"
  local makefile_path
  shift 2

  rm -rf "$target_path"
  git clone \
    --depth=1 \
    --no-tags \
    "$repourl" \
    "$target_path"

  for makefile_path in "$@"; do
    [ -f "$target_path/$makefile_path" ] || die "Package Makefile not found: $target_path/$makefile_path"
  done
}

remove_builtin_packages() {
  rm -rf \
    "$SDK_ROOT/feeds/packages/net/aria2" \
    "$SDK_ROOT/feeds/packages/net/ariang" \
    "$SDK_ROOT/feeds/packages/net/frp" \
    "$SDK_ROOT/feeds/packages/lang/golang" \
    "$SDK_ROOT/feeds/packages/net/nginx" \
    "$SDK_ROOT/feeds/luci/applications/luci-app-frpc" \
    "$SDK_ROOT/feeds/luci/applications/luci-app-frps" \
    "$SDK_ROOT/feeds/luci/applications/luci-app-argon-config" \
    "$SDK_ROOT/feeds/luci/themes/luci-theme-argon"
}

load_custom_packages() {
  mkdir -p "$SPARSE_ROOT"

  git_sparse_clone aria2 "$PACKAGES_REPO" feeds/packages net/aria2
  git_sparse_clone ariang "$PACKAGES_REPO" feeds/packages net/ariang
  git_sparse_clone master "$PACKAGES_REPO" feeds/packages lang/golang
  git_sparse_clone frp-binary "$PACKAGES_REPO" feeds/packages net/frp
  git_sparse_clone nginx "$PACKAGES_REPO" feeds/packages net/nginx
  git_sparse_clone frp "$LUCI_REPO" feeds/luci \
    applications/luci-app-frpc \
    applications/luci-app-frps
  sed -i '/^LUCI_EXTRA_DEPENDS:=/d' \
    "$SDK_ROOT/feeds/luci/applications/luci-app-frpc/Makefile" \
    "$SDK_ROOT/feeds/luci/applications/luci-app-frps/Makefile"
  git_clone_package_repo "$GECOOSAC_REPO" "$SDK_ROOT/package/luci-app-gecoosac" \
    gecoosac/Makefile \
    luci-app-gecoosac/Makefile
  git_clone_package_repo "$ARGON_REPO" "$SDK_ROOT/package/luci-theme-argon" Makefile
  git_clone_package_repo "$ARGON_CONFIG_REPO" "$SDK_ROOT/package/luci-app-argon-config" Makefile
  git_clone_package_repo "$AURORA_REPO" "$SDK_ROOT/package/luci-theme-aurora" Makefile
  git_clone_package_repo "$AURORA_CONFIG_REPO" "$SDK_ROOT/package/luci-app-aurora-config" Makefile
  git_clone_package_repo "$OPENLIST2_REPO" "$SDK_ROOT/package/openlist2" \
    openlist2/Makefile \
    luci-app-openlist2/Makefile
  git_clone_package_repo "$LUCKY_REPO" "$SDK_ROOT/package/lucky" \
    lucky/Makefile \
    luci-app-lucky/Makefile
}

prune_luci_translations() {
  local lang_dir
  local lang_name
  local po_dir
  local removed_count=0
  local root_dir

  for root_dir in \
    "$SDK_ROOT/package/luci-app-gecoosac" \
    "$SDK_ROOT/package/luci-app-argon-config" \
    "$SDK_ROOT/package/luci-theme-argon" \
    "$SDK_ROOT/package/luci-app-aurora-config" \
    "$SDK_ROOT/package/luci-theme-aurora" \
    "$SDK_ROOT/package/roc" \
    "$SDK_ROOT/package/feeds/luci" \
    "$SDK_ROOT/feeds/luci/applications"; do
    [ -d "$root_dir" ] || continue

    while IFS= read -r -d '' po_dir; do
      while IFS= read -r -d '' lang_dir; do
        lang_name="$(basename "$lang_dir")"
        case "$lang_name" in
          templates | zh_Hans | zh_Hant)
            ;;
          *)
            rm -rf "$lang_dir"
            removed_count=$((removed_count + 1))
            ;;
        esac
      done < <(find "$po_dir" -mindepth 1 -maxdepth 1 -type d -print0)
    done < <(find "$root_dir" -type d -name po -print0)
  done

  log "Pruned LuCI translations: kept zh_Hans and zh_Hant, removed $removed_count other language directories"
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
  load_inline_target_profile "$OPENWRT_TARGET_PROFILE"
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

add_compile_target() {
  local compile_target="$1"
  local existing_target

  for existing_target in "${COMPILE_TARGETS[@]}"; do
    [ "$existing_target" != "$compile_target" ] || return
  done

  COMPILE_TARGETS+=("$compile_target")
}

add_artifact_package() {
  local package_name="$1"
  local existing_package

  for existing_package in "${ARTIFACT_PACKAGE_NAMES[@]}"; do
    [ "$existing_package" != "$package_name" ] || return
  done

  ARTIFACT_PACKAGE_NAMES+=("$package_name")
}

add_luci_i18n_packages() {
  local app_name="$1"

  add_artifact_package "luci-i18n-${app_name}-zh-cn"
  add_artifact_package "luci-i18n-${app_name}-zh-tw"
}

generate_artifact_filters() {
  ARTIFACT_PACKAGE_NAMES=()

  if selection_in luci-app-aria2 && {
    config_package_enabled aria2 ||
      config_package_enabled luci-app-aria2
  }; then
    add_artifact_package aria2
  fi

  if selection_in luci-app-aria2 && config_package_enabled ariang; then
    add_artifact_package ariang
  fi

  if selection_in luci-app-aria2 && config_package_enabled luci-app-aria2; then
    add_artifact_package luci-app-aria2
    add_luci_i18n_packages aria2
  fi

  if { selection_in frp && config_package_enabled frpc; } ||
    { selection_in luci-app-frpc && {
      config_package_enabled frpc ||
        config_package_enabled luci-app-frpc
    }; }; then
    add_artifact_package frpc
  fi

  if { selection_in frp && config_package_enabled frps; } ||
    { selection_in luci-app-frps && {
      config_package_enabled frps ||
        config_package_enabled luci-app-frps
    }; }; then
    add_artifact_package frps
  fi

  if selection_in frp luci-app-frpc && config_package_enabled luci-app-frpc; then
    add_artifact_package luci-app-frpc
    add_luci_i18n_packages frpc
  fi

  if selection_in frp luci-app-frps && config_package_enabled luci-app-frps; then
    add_artifact_package luci-app-frps
    add_luci_i18n_packages frps
  fi

  selection_in nginx && config_package_enabled nginx && add_artifact_package nginx
  selection_in nginx && config_package_enabled nginx-full && add_artifact_package nginx-full
  selection_in nginx && config_package_enabled nginx-ssl && add_artifact_package nginx-ssl

  if selection_in luci-app-openlist2 && {
    config_package_enabled openlist2 ||
      config_package_enabled luci-app-openlist2
  }; then
    add_artifact_package openlist2
  fi

  if selection_in luci-app-lucky && {
    config_package_enabled lucky ||
      config_package_enabled luci-app-lucky
  }; then
    add_artifact_package lucky
  fi

  if selection_in luci-app-gecoosac && {
    config_package_enabled gecoosac ||
      config_package_enabled luci-app-gecoosac
  }; then
    add_artifact_package gecoosac
  fi

  if selection_in luci-app-gecoosac && config_package_enabled luci-app-gecoosac; then
    add_artifact_package luci-app-gecoosac
    add_luci_i18n_packages gecoosac
  fi

  if selection_in luci-app-openlist2 && config_package_enabled luci-app-openlist2; then
    add_artifact_package luci-app-openlist2
    add_luci_i18n_packages openlist2
  fi

  if selection_in luci-app-lucky && config_package_enabled luci-app-lucky; then
    add_artifact_package luci-app-lucky
    add_artifact_package luci-i18n-lucky-zh-cn
  fi

  if selection_in luci-theme-aurora; then
    config_package_enabled luci-theme-aurora && add_artifact_package luci-theme-aurora
    if config_package_enabled luci-app-aurora-config; then
      add_artifact_package luci-app-aurora-config
      add_luci_i18n_packages aurora-config
    fi
  fi

  if selection_in luci-theme-argon; then
    config_package_enabled luci-theme-argon && add_artifact_package luci-theme-argon
    if config_package_enabled luci-app-argon-config; then
      add_artifact_package luci-app-argon-config
      add_luci_i18n_packages argon-config
    fi
  fi

  [ "${#ARTIFACT_PACKAGE_NAMES[@]}" -gt 0 ] || die "No package artifact filters were generated for PACKAGE_SELECTION=$PACKAGE_SELECTION"
}

artifact_package_allowed() {
  local package_file_name="$1"
  local package_name

  for package_name in "${ARTIFACT_PACKAGE_NAMES[@]}"; do
    package_file_matches_name "$package_file_name" "$package_name" && return 0
  done

  return 1
}

package_file_matches_name() {
  local package_file_name="$1"
  local package_name="$2"

  case "$package_file_name" in
    "${package_name}_"* | "${package_name}-"[0-9]* | "${package_name}-git"* | "${package_name}-v"[0-9]*)
      return 0
      ;;
  esac

  return 1
}

artifact_package_group() {
  local package_file_name="$1"

  if package_file_matches_name "$package_file_name" aria2 ||
    package_file_matches_name "$package_file_name" ariang ||
    package_file_matches_name "$package_file_name" luci-app-aria2 ||
    package_file_matches_name "$package_file_name" luci-i18n-aria2-zh-cn ||
    package_file_matches_name "$package_file_name" luci-i18n-aria2-zh-tw; then
    printf 'luci-app-aria2\n'
    return 0
  fi

  if package_file_matches_name "$package_file_name" frpc ||
    package_file_matches_name "$package_file_name" luci-app-frpc ||
    package_file_matches_name "$package_file_name" luci-i18n-frpc-zh-cn ||
    package_file_matches_name "$package_file_name" luci-i18n-frpc-zh-tw; then
    printf 'luci-app-frpc\n'
    return 0
  fi

  if package_file_matches_name "$package_file_name" frps ||
    package_file_matches_name "$package_file_name" luci-app-frps ||
    package_file_matches_name "$package_file_name" luci-i18n-frps-zh-cn ||
    package_file_matches_name "$package_file_name" luci-i18n-frps-zh-tw; then
    printf 'luci-app-frps\n'
    return 0
  fi

  if package_file_matches_name "$package_file_name" gecoosac ||
    package_file_matches_name "$package_file_name" luci-app-gecoosac ||
    package_file_matches_name "$package_file_name" luci-i18n-gecoosac-zh-cn ||
    package_file_matches_name "$package_file_name" luci-i18n-gecoosac-zh-tw; then
    printf 'luci-app-gecoosac\n'
    return 0
  fi

  if package_file_matches_name "$package_file_name" openlist2 ||
    package_file_matches_name "$package_file_name" luci-app-openlist2 ||
    package_file_matches_name "$package_file_name" luci-i18n-openlist2-zh-cn ||
    package_file_matches_name "$package_file_name" luci-i18n-openlist2-zh-tw; then
    printf 'luci-app-openlist2\n'
    return 0
  fi

  if package_file_matches_name "$package_file_name" lucky ||
    package_file_matches_name "$package_file_name" luci-app-lucky ||
    package_file_matches_name "$package_file_name" luci-i18n-lucky-zh-cn; then
    printf 'luci-app-lucky\n'
    return 0
  fi

  if package_file_matches_name "$package_file_name" luci-theme-aurora ||
    package_file_matches_name "$package_file_name" luci-app-aurora-config ||
    package_file_matches_name "$package_file_name" luci-i18n-aurora-config-zh-cn ||
    package_file_matches_name "$package_file_name" luci-i18n-aurora-config-zh-tw; then
    printf 'luci-theme-aurora\n'
    return 0
  fi

  if package_file_matches_name "$package_file_name" luci-theme-argon ||
    package_file_matches_name "$package_file_name" luci-app-argon-config ||
    package_file_matches_name "$package_file_name" luci-i18n-argon-config-zh-cn ||
    package_file_matches_name "$package_file_name" luci-i18n-argon-config-zh-tw; then
    printf 'luci-theme-argon\n'
    return 0
  fi

  if package_file_matches_name "$package_file_name" nginx ||
    package_file_matches_name "$package_file_name" nginx-full ||
    package_file_matches_name "$package_file_name" nginx-ssl; then
    printf 'nginx\n'
    return 0
  fi

  return 1
}

release_package_name() {
  local package_file="$1"
  local group_name="$2"
  local package_arch
  local package_release_name
  local package_file_name
  local safe_package_name
  local sdk_prefix

  package_file_name="$(basename "$package_file")"
  safe_package_name="${package_file_name//\~/-}"
  package_arch="$(release_package_arch_suffix "$group_name")"
  sdk_prefix="$(normalize_sdk_version "$OPENWRT_SDK_VERSION")-"

  case "$safe_package_name" in
    *.apk)
      package_release_name="${safe_package_name%.apk}-$package_arch.apk"
      ;;
    *_all.ipk)
      package_release_name="${safe_package_name%_all.ipk}_$package_arch.ipk"
      ;;
    *.ipk)
      local package_path_arch
      package_path_arch="$(basename "$(dirname "$(dirname "$package_file")")")"
      case "$safe_package_name" in
        *_"$package_path_arch".ipk)
          package_release_name="${safe_package_name%_"$package_path_arch".ipk}_$package_arch.ipk"
          ;;
        *)
          package_release_name="${safe_package_name%.ipk}_$package_arch.ipk"
          ;;
      esac
      ;;
    *)
      package_release_name="$safe_package_name"
      ;;
  esac

  case "$package_release_name" in
    main-* | 23.05-* | 24.10-* | 25.12-*)
      printf '%s\n' "$package_release_name"
      ;;
    *)
      printf '%s%s\n' "$sdk_prefix" "$package_release_name"
      ;;
  esac
}

release_package_arch_suffix() {
  local group_name="$1"

  if artifact_group_is_arch_independent "$group_name"; then
    printf 'all\n'
    return
  fi

  printf '%s\n' "${PACKAGE_ARCH_NAME//\//-}"
}

artifact_zip_name() {
  local group_name="$1"
  local safe_arch_name="${PACKAGE_ARCH_NAME//\//-}"
  local sdk_prefix

  sdk_prefix="$(normalize_sdk_version "$OPENWRT_SDK_VERSION")"

  if artifact_group_is_arch_independent "$group_name"; then
    printf '%s-%s-all.zip\n' "$sdk_prefix" "$group_name"
    return
  fi

  printf '%s-%s-%s.zip\n' "$sdk_prefix" "$group_name" "$safe_arch_name"
}

artifact_group_should_be_skipped() {
  local group_name="$1"

  artifact_group_is_arch_independent "$group_name" || return 1
  [ "$PACKAGE_SELECTED_ARCH" = ALL ] || return 1
  [ "$PACKAGE_ARCH_NAME" != x86-64 ]
}

artifact_group_is_arch_independent() {
  local group_name="$1"

  [ "$group_name" = luci-theme-argon ] || [ "$group_name" = luci-theme-aurora ]
}

generate_compile_targets() {
  COMPILE_TARGETS=()

  if selection_in luci-app-aria2 && {
    config_package_enabled aria2 ||
      config_package_enabled luci-app-aria2
  }; then
    add_compile_target package/feeds/packages/aria2/compile
  fi

  if selection_in luci-app-aria2 && {
    config_package_enabled ariang ||
      config_package_enabled ariang-nginx
  }; then
    add_compile_target package/feeds/packages/ariang/compile
  fi

  if { selection_in frp && {
    config_package_enabled frpc ||
      config_package_enabled frps
  }; } || { selection_in luci-app-frpc && {
    config_package_enabled frpc ||
      config_package_enabled luci-app-frpc
  }; } || { selection_in luci-app-frps && {
    config_package_enabled frps ||
      config_package_enabled luci-app-frps
  }; }; then
    add_compile_target package/feeds/packages/frp/compile
  fi

  if selection_in nginx && {
    config_package_enabled nginx ||
    config_package_enabled nginx-full ||
    config_package_enabled nginx-ssl
  }; then
    add_compile_target package/feeds/packages/nginx/compile
  fi

  if selection_in luci-app-openlist2 && {
    config_package_enabled openlist2 ||
      config_package_enabled luci-app-openlist2
  }; then
    add_compile_target package/openlist2/openlist2/compile
  fi

  if selection_in luci-app-lucky && {
    config_package_enabled lucky ||
      config_package_enabled luci-app-lucky
  }; then
    add_compile_target package/lucky/lucky/compile
  fi

  if selection_in frp luci-app-frpc && config_package_enabled luci-app-frpc; then
    add_compile_target package/feeds/luci/luci-app-frpc/compile
  fi

  if selection_in frp luci-app-frps && config_package_enabled luci-app-frps; then
    add_compile_target package/feeds/luci/luci-app-frps/compile
  fi

  if selection_in luci-app-aria2 && config_package_enabled luci-app-aria2 && [ -d "$SDK_ROOT/package/feeds/luci/luci-app-aria2" ]; then
    add_compile_target package/feeds/luci/luci-app-aria2/compile
  fi

  if selection_in luci-app-gecoosac && {
    config_package_enabled gecoosac ||
      config_package_enabled luci-app-gecoosac
  }; then
    add_compile_target package/luci-app-gecoosac/gecoosac/compile
  fi

  if selection_in luci-app-gecoosac && config_package_enabled luci-app-gecoosac; then
    add_compile_target package/luci-app-gecoosac/luci-app-gecoosac/compile
  fi

  if selection_in luci-app-openlist2 && config_package_enabled luci-app-openlist2; then
    add_compile_target package/openlist2/luci-app-openlist2/compile
  fi

  if selection_in luci-app-lucky && config_package_enabled luci-app-lucky; then
    add_compile_target package/lucky/luci-app-lucky/compile
  fi

  if selection_in luci-theme-aurora && ! artifact_group_should_be_skipped luci-theme-aurora; then
    config_package_enabled luci-theme-aurora && add_compile_target package/luci-theme-aurora/compile
    config_package_enabled luci-app-aurora-config && add_compile_target package/luci-app-aurora-config/compile
  fi

  if selection_in luci-theme-argon && ! artifact_group_should_be_skipped luci-theme-argon; then
    config_package_enabled luci-theme-argon && add_compile_target package/luci-theme-argon/compile
    config_package_enabled luci-app-argon-config && add_compile_target package/luci-app-argon-config/compile
  fi

  [ "${#COMPILE_TARGETS[@]}" -gt 0 ] || die "No matching package compile targets were enabled by $PACKAGE_CONFIG_FILES for PACKAGE_SELECTION=$PACKAGE_SELECTION"
}

copy_artifacts() {
  local package_bin_dir="$SDK_ROOT/bin/packages"
  local copied_count=0
  local group_dir
  local group_name
  local groups=()
  local -A group_counts=()
  local package_file
  local package_file_name
  local release_name
  local skipped_count=0
  local staging_dir="$RUNNER_TEMP/package-artifact-groups"
  local target_file
  local zip_count=0
  local zip_file

  if [ ! -d "$package_bin_dir" ]; then
    die "SDK package output directory was not created: $package_bin_dir"
  fi

  if [ -z "$(find "$package_bin_dir" -type f \( -name '*.ipk' -o -name '*.apk' \) -print -quit)" ]; then
    die "No compiled .ipk or .apk files were found under $package_bin_dir"
  fi

  command -v zip >/dev/null 2>&1 || die "zip command was not found"

  rm -rf "$OUTPUT_DIR" "$staging_dir"
  mkdir -p "$OUTPUT_DIR" "$staging_dir"
  while IFS= read -r -d '' package_file; do
    package_file_name="$(basename "$package_file")"
    if ! artifact_package_allowed "$package_file_name"; then
      skipped_count=$((skipped_count + 1))
      continue
    fi

    group_name="$(artifact_package_group "$package_file_name")" ||
      die "No artifact group was found for package file: $package_file_name"
    if artifact_group_should_be_skipped "$group_name"; then
      skipped_count=$((skipped_count + 1))
      continue
    fi

    if [ -z "${group_counts[$group_name]+set}" ]; then
      group_counts[$group_name]=0
      groups+=("$group_name")
    fi

    group_dir="$staging_dir/$group_name"
    mkdir -p "$group_dir"

    release_name="$(release_package_name "$package_file" "$group_name")"
    target_file="$group_dir/$release_name"
    [ ! -e "$target_file" ] || die "Duplicate package artifact name: $target_file"
    cp -a "$package_file" "$target_file"
    group_counts[$group_name]=$((group_counts[$group_name] + 1))
    copied_count=$((copied_count + 1))
  done < <(find "$package_bin_dir" -type f \( -name '*.ipk' -o -name '*.apk' \) -print0)

  [ "$copied_count" -gt 0 ] || die "No selected package files were copied from $package_bin_dir"

  for group_name in "${groups[@]}"; do
    group_dir="$staging_dir/$group_name"
    [ "${group_counts[$group_name]}" -gt 0 ] || die "No files were staged for artifact group: $group_name"

    zip_file="$OUTPUT_DIR/$(artifact_zip_name "$group_name")"
    [ ! -e "$zip_file" ] || die "Duplicate package zip artifact name: $zip_file"
    (
      cd "$group_dir"
      zip -q -r "$zip_file" .
    )
    zip_count=$((zip_count + 1))
  done

  rm -rf "$staging_dir"
  log "Packed $copied_count selected package files into $zip_count grouped zip files under $OUTPUT_DIR; skipped $skipped_count dependency files"

  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "PACKAGE_OUTPUT_DIR=$OUTPUT_DIR" >> "$GITHUB_ENV"
    echo "RESOLVED_SDK_URL=$RESOLVED_SDK_URL" >> "$GITHUB_ENV"
  fi
}

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

PACKAGE_SELECTION="$(normalize_package_selection "$PACKAGE_SELECTION")"
OPENWRT_SDK_VERSION="$(normalize_sdk_version "$OPENWRT_SDK_VERSION")"

log "Download OpenWrt SDK"
log "Selected package group: $PACKAGE_SELECTION"
log "Selected OpenWrt SDK version: $OPENWRT_SDK_VERSION"
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

log "Load custom packages"
remove_builtin_packages
load_custom_packages

log "Refresh SDK feed indexes"
./scripts/feeds update -i -a

log "Install SDK feeds"
./scripts/feeds install -a
prune_luci_translations

log "Load package config"
load_config_files
make defconfig
generate_compile_targets
generate_artifact_filters

log "Compile packages"
for compile_target in "${COMPILE_TARGETS[@]}"; do
  make -j"$(nproc)" "$compile_target" || make -j1 "$compile_target" V=s
done

log "Collect package artifacts"
copy_artifacts
