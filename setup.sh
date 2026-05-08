#!/usr/bin/env bash
set -euo pipefail

readonly DROIDSPACES_RAW_BASE="https://raw.githubusercontent.com/ravindu644/Droidspaces-OSS/main/Documentation/resources/kernel-patches/GKI"
readonly PATCH_BELOW_612="$DROIDSPACES_RAW_BASE/below-kernel-6.12/001.GKI-below-6.12-fix_sysvipc_kabi_6_7_8.patch"
readonly PATCH_510_MQUEUE="$DROIDSPACES_RAW_BASE/below-kernel-6.12/002.5.10_or_lower_use_android_abi_padding_for_posix_mqueue.patch"
readonly PATCH_612_PLUS="$DROIDSPACES_RAW_BASE/kernel-6.12/001.GKI-6.12-or-above-fix_sysvipc_kabi.patch"

info() {
  printf '[DroidSpaces-OSS] %s\n' "$*" >&2
}

fail() {
  printf '[DroidSpaces-OSS][ERROR] %s\n' "$*" >&2
  exit 1
}

require_file() {
  [ -f "$1" ] || fail "required file not found: $1"
}

detect_kernel_version() {
  local makefile="$KERNEL_ROOT/common/Makefile"
  local version=""
  local patchlevel=""
  local sublevel=""

  if [ -f "$makefile" ]; then
    version="$(awk -F'= *' '$1 ~ /^VERSION / { print $2; exit }' "$makefile" | tr -d '[:space:]')"
    patchlevel="$(awk -F'= *' '$1 ~ /^PATCHLEVEL / { print $2; exit }' "$makefile" | tr -d '[:space:]')"
    sublevel="$(awk -F'= *' '$1 ~ /^SUBLEVEL / { print $2; exit }' "$makefile" | tr -d '[:space:]')"
  fi

  if [ -z "$version" ] || [ -z "$patchlevel" ]; then
    case "${CONFIG:-}" in
      *-5.10-*) version=5; patchlevel=10 ;;
      *-5.15-*) version=5; patchlevel=15 ;;
      *-6.1-*) version=6; patchlevel=1 ;;
      *-6.6-*) version=6; patchlevel=6 ;;
      *-6.12-*) version=6; patchlevel=12 ;;
      *) fail "unable to detect kernel version from $makefile or CONFIG=${CONFIG:-unset}" ;;
    esac
  fi

  if [ -z "$sublevel" ]; then
    sublevel="$(printf '%s\n' "${CONFIG:-}" | sed -n 's/.*-[0-9]\+\.[0-9]\+-\([0-9]\+\).*/\1/p')"
  fi

  KERNEL_MAJOR="$version"
  KERNEL_MINOR="$patchlevel"
  KERNEL_SUBLEVEL="${sublevel:-0}"
  KERNEL_MM="${KERNEL_MAJOR}.${KERNEL_MINOR}"
}

kernel_version_code() {
  printf '%03d%03d\n' "$KERNEL_MAJOR" "$KERNEL_MINOR"
}

kernel_sublevel_between() {
  local min="$1"
  local max="$2"

  [[ "$KERNEL_SUBLEVEL" =~ ^[0-9]+$ ]] || return 1
  [ "$KERNEL_SUBLEVEL" -ge "$min" ] && [ "$KERNEL_SUBLEVEL" -le "$max" ]
}

download_patch() {
  local url="$1"
  local name="$2"
  local target="$RUNNER_TEMP/droidspaces-$name"

  mkdir -p "$RUNNER_TEMP"
  info "Downloading $name"
  curl -fsSL "$url" -o "$target" || fail "failed to download patch: $url"
  printf '%s\n' "$target"
}

try_apply_patch_file() {
  local patch="$1"
  local name
  name="$(basename "$patch")"

  if git -C "$KERNEL_ROOT/common" apply --check "$patch" >/dev/null 2>&1; then
    git -C "$KERNEL_ROOT/common" apply "$patch"
    info "Applied $name"
    return 0
  elif git -C "$KERNEL_ROOT/common" apply --reverse --check "$patch" >/dev/null 2>&1; then
    info "Already applied $name"
    return 0
  else
    info "Patch check failed for $name"
    return 1
  fi
}

apply_sysvipc_below_612_compat() {
  local sched="$KERNEL_ROOT/common/include/linux/sched.h"

  require_file "$sched"
  if grep -qF 'ANDROID_KABI_USE(6, struct sysv_sem sysvsem);' "$sched"; then
    info "SYSVIPC below-6.12 kABI fallback already applied"
    return 0
  fi

  perl -0pi -e 's/#ifdef CONFIG_SYSVIPC\n\tstruct sysv_sem\s+sysvsem;\n\tstruct sysv_shm\s+sysvshm;\n#endif/#ifdef CONFIG_SYSVIPC\n\t\/\/ struct sysv_sem\t\t\tsysvsem;\n\t\/\/ struct sysv_shm\t\t\tsysvshm;\n#endif/s' "$sched"
  perl -0pi -e 's/\tANDROID_KABI_RESERVE\(6\);\n\tANDROID_KABI_RESERVE\(7\);\n\tANDROID_KABI_RESERVE\(8\);/\n#ifdef CONFIG_SYSVIPC\n\tANDROID_KABI_USE(6, struct sysv_sem sysvsem);\n\t_ANDROID_KABI_REPLACE(ANDROID_KABI_RESERVE(7); ANDROID_KABI_RESERVE(8), struct sysv_shm sysvshm);\n#else\n\tANDROID_KABI_RESERVE(6);\n\tANDROID_KABI_RESERVE(7);\n\tANDROID_KABI_RESERVE(8);\n#endif/s' "$sched"

  grep -qF '// struct sysv_sem' "$sched" || fail "failed to comment original SYSVIPC sysvsem field"
  grep -qF 'ANDROID_KABI_USE(6, struct sysv_sem sysvsem);' "$sched" || fail "failed to inject SYSVIPC kABI reserve use"
  info "Applied SYSVIPC below-6.12 kABI fallback"
}

apply_mqueue_510_compat() {
  local user_h="$KERNEL_ROOT/common/include/linux/sched/user.h"

  require_file "$user_h"
  if grep -qF 'ANDROID_KABI_USE(1, unsigned long mq_bytes);' "$user_h"; then
    info "POSIX mqueue kABI fallback already applied"
    return 0
  fi

  perl -0pi -e 's/#ifdef CONFIG_POSIX_MQUEUE\n\t\/\* protected by mq_lock\t\*\/\n\tunsigned long mq_bytes;\t\/\* How many bytes can be allocated to mqueue\? \*\/\n#endif/#ifdef CONFIG_POSIX_MQUEUE\n\t\/\* protected by mq_lock\t\*\/\n\t\/\/unsigned long mq_bytes;\t\/\* How many bytes can be allocated to mqueue? \*\/\n#endif/s' "$user_h"
  perl -0pi -e 's/\tANDROID_KABI_RESERVE\(1\);\n\tANDROID_KABI_RESERVE\(2\);\n\tANDROID_OEM_DATA_ARRAY\(1, 2\);/\n#if defined(CONFIG_POSIX_MQUEUE)\n\tANDROID_KABI_USE(1, unsigned long mq_bytes);\n\tANDROID_KABI_RESERVE(2);\n\tANDROID_OEM_DATA_ARRAY(1, 2);\n#else\n\tANDROID_KABI_RESERVE(1);\n\tANDROID_KABI_RESERVE(2);\n\tANDROID_OEM_DATA_ARRAY(1, 2);\n#endif/s' "$user_h"

  grep -qF 'ANDROID_KABI_USE(1, unsigned long mq_bytes);' "$user_h" || fail "failed to inject POSIX mqueue kABI reserve use"
  info "Applied POSIX mqueue 5.10 kABI fallback"
}

apply_sysvipc_612_plus_compat() {
  local sched="$KERNEL_ROOT/common/include/linux/sched.h"

  require_file "$sched"
  if grep -qF 'char __kabi_ignored_0;' "$sched"; then
    info "SYSVIPC 6.12+ kABI fallback already applied"
    return 0
  fi

  perl -0pi -e 's/(\n\tunsigned int\s+rt_priority;\n)/$1\n#ifdef CONFIG_SYSVIPC\n\tunion {\n\t\tchar __kabi_ignored_0;\n\t\tstruct sysv_sem\t\t\tsysvsem;\n\t}__attribute__((packed));\n\tunion {\n\t\tchar __kabi_ignored_1;\n\t\tstruct sysv_shm\t\t\tsysvshm;\n\t}__attribute__((packed));\n#endif\n/s or die "rt_priority anchor not found\n";' "$sched" || fail "failed to inject SYSVIPC 6.12+ packed fields"
  perl -0pi -e 's/#ifdef CONFIG_SYSVIPC\n\tstruct sysv_sem\s+sysvsem;\n\tstruct sysv_shm\s+sysvshm;\n#endif/#ifdef CONFIG_SYSVIPC\n\t\/\/ struct sysv_sem\t\t\tsysvsem;\n\t\/\/ struct sysv_shm\t\t\tsysvshm;\n#endif/s' "$sched"

  grep -qF 'char __kabi_ignored_0;' "$sched" || fail "failed to inject SYSVIPC 6.12+ ignored field"
  grep -qF '// struct sysv_sem' "$sched" || fail "failed to comment original SYSVIPC fields"
  info "Applied SYSVIPC 6.12+ kABI fallback"
}

ensure_export_header() {
  local file="$1"

  if grep -qF '#include <linux/export.h>' "$file"; then
    return 0
  fi

  perl -0pi -e 's/(\n#include "util\.h")/\n#include <linux\/export.h>$1/s or die "util.h include anchor not found\n";' "$file" \
    || fail "failed to add linux/export.h to $file"
  grep -qF '#include <linux/export.h>' "$file" || fail "failed to verify linux/export.h in $file"
}

apply_rust_binder_ipc_export_612_23_69() {
  local msgutil="$KERNEL_ROOT/common/ipc/msgutil.c"
  local namespace="$KERNEL_ROOT/common/ipc/namespace.c"

  if [ "$KERNEL_MM" != "6.12" ] || ! kernel_sublevel_between 23 69; then
    return 0
  fi

  require_file "$msgutil"
  require_file "$namespace"

  if ! grep -qF 'EXPORT_SYMBOL(init_ipc_ns);' "$msgutil"; then
    ensure_export_header "$msgutil"
    perl -0pi -e 's/(struct\s+ipc_namespace\s+init_ipc_ns\b[^=]*=\s*\{.*?\n\};)/$1\nEXPORT_SYMBOL(init_ipc_ns);/s or die "init_ipc_ns definition anchor not found\n";' "$msgutil" \
      || fail "failed to export init_ipc_ns"
    grep -qF 'EXPORT_SYMBOL(init_ipc_ns);' "$msgutil" || fail "failed to verify init_ipc_ns export"
    info "Exported init_ipc_ns for 6.12.$KERNEL_SUBLEVEL rust_binder"
  fi

  if ! grep -qF 'EXPORT_SYMBOL(put_ipc_ns);' "$namespace"; then
    ensure_export_header "$namespace"
    if grep -qE '^static[[:space:]]+(inline[[:space:]]+)?struct[[:space:]]+ipc_namespace[[:space:]]+\*to_ipc_ns[[:space:]]*\(' "$namespace"; then
      perl -0pi -e 's/\n(static\s+(?:inline\s+)?struct\s+ipc_namespace\s+\*to_ipc_ns\s*\()/\nEXPORT_SYMBOL(put_ipc_ns);\n\n$1/s or die "to_ipc_ns anchor not found\n";' "$namespace" \
        || fail "failed to export put_ipc_ns before to_ipc_ns"
    else
      perl -0pi -e 's/\n(static\s+struct\s+ns_common\s+\*ipcns_get\s*\()/\nEXPORT_SYMBOL(put_ipc_ns);\n\n$1/s or die "ipcns_get anchor not found\n";' "$namespace" \
        || fail "failed to export put_ipc_ns before ipcns_get"
    fi
    grep -qF 'EXPORT_SYMBOL(put_ipc_ns);' "$namespace" || fail "failed to verify put_ipc_ns export"
    info "Exported put_ipc_ns for 6.12.$KERNEL_SUBLEVEL rust_binder"
  fi
}

apply_droidspaces_patches() {
  if [ "${DROIDSPACES_SKIP_PATCHES:-0}" = "1" ]; then
    info "Skipping kABI patches because DROIDSPACES_SKIP_PATCHES=1"
    return
  fi

  require_file "$KERNEL_ROOT/common/include/linux/sched.h"
  local code
  code="$(kernel_version_code)"

  if [ "$code" -lt "$(printf '%03d%03d\n' 6 12)" ]; then
    if ! try_apply_patch_file "$(download_patch "$PATCH_BELOW_612" "001.GKI-below-6.12-fix_sysvipc_kabi_6_7_8.patch")"; then
      apply_sysvipc_below_612_compat
    fi
    if [ "$code" -le "$(printf '%03d%03d\n' 5 10)" ]; then
      require_file "$KERNEL_ROOT/common/include/linux/sched/user.h"
      if ! try_apply_patch_file "$(download_patch "$PATCH_510_MQUEUE" "002.5.10_or_lower_use_android_abi_padding_for_posix_mqueue.patch")"; then
        apply_mqueue_510_compat
      fi
    fi
  else
    if ! try_apply_patch_file "$(download_patch "$PATCH_612_PLUS" "001.GKI-6.12-or-above-fix_sysvipc_kabi.patch")"; then
      apply_sysvipc_612_plus_compat
    fi
  fi
}

set_config_y() {
  local symbol="$1"
  local file="$DEFCONFIG"

  if grep -q "^${symbol}=y$" "$file"; then
    return
  fi

  if grep -q "^# ${symbol} is not set$" "$file"; then
    sed -i "s/^# ${symbol} is not set$/${symbol}=y/" "$file"
  elif grep -q "^${symbol}=" "$file"; then
    sed -i "s/^${symbol}=.*/${symbol}=y/" "$file"
  else
    printf '%s=y\n' "$symbol" >> "$file"
  fi
}

symbol_declared() {
  local symbol="${1#CONFIG_}"
  local file

  while IFS= read -r -d '' file; do
    if grep -Eq "^[[:space:]]*(menuconfig|config)[[:space:]]+${symbol}([[:space:]]|$)" "$file"; then
      return 0
    fi
  done < <(find "$KERNEL_ROOT/common" -type f -name 'Kconfig*' -print0)

  return 1
}

set_required_config_y() {
  local symbol="$1"

  if ! symbol_declared "$symbol"; then
    fail "required Kconfig symbol is not declared: $symbol"
  fi

  set_config_y "$symbol"
}

set_optional_config_y() {
  local symbol="$1"

  if ! symbol_declared "$symbol"; then
    info "Skipping optional config not declared by this kernel: $symbol"
    return
  fi

  set_config_y "$symbol"
}

configure_defconfig() {
  require_file "$DEFCONFIG"

  local required_configs=(
    CONFIG_SYSVIPC
    CONFIG_POSIX_MQUEUE
    CONFIG_IPC_NS
    CONFIG_PID_NS
    CONFIG_DEVTMPFS
  )

  local optional_configs=(
    CONFIG_NETFILTER_XT_MATCH_ADDRTYPE
    CONFIG_NETFILTER_XT_TARGET_REJECT
    CONFIG_NETFILTER_XT_TARGET_LOG
    CONFIG_NETFILTER_XT_MATCH_RECENT
    CONFIG_IP_SET
    CONFIG_IP_SET_HASH_IP
    CONFIG_IP_SET_HASH_NET
    CONFIG_NETFILTER_XT_SET
  )

  for config in "${required_configs[@]}"; do
    set_required_config_y "$config"
  done

  for config in "${optional_configs[@]}"; do
    set_optional_config_y "$config"
  done
}

main() {
  : "${KERNEL_ROOT:?KERNEL_ROOT is required}"
  : "${DEFCONFIG:?DEFCONFIG is required}"
  : "${RUNNER_TEMP:=${TMPDIR:-/tmp}}"

  require_file "$KERNEL_ROOT/common/Makefile"
  detect_kernel_version

  case "$KERNEL_MM" in
    5.10|5.15|6.1|6.6|6.12) ;;
    *) fail "unsupported ABK GKI kernel version: $KERNEL_MM" ;;
  esac

  info "Configuring DroidSpaces for ABK GKI $KERNEL_MM"
  apply_droidspaces_patches
  apply_rust_binder_ipc_export_612_23_69
  configure_defconfig
  info "DroidSpaces kernel configuration complete"
}

main "$@"
