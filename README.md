# DroidSpaces-OSS ABK Module

ABK custom external module for enabling DroidSpaces-OSS kernel support on AnyBase Kernel GKI builds.

This module follows the upstream DroidSpaces kernel guide:
https://github.com/ravindu644/Droidspaces-OSS/blob/main/Documentation/Kernel-Configuration.md

## Usage

Enable ABK custom external modules and add this module in the `after_patch` stage:

```text
https://github.com/xingguangcuican6666/DroidSpaces-OSS-module.git;after_patch
```

The module entrypoint is `setup.sh`. ABK runs it from the module repository root after built-in source integrations and before the final build.

## Supported Kernels

This module targets ABK GKI kernels:

- `5.10`
- `5.15`
- `6.1`
- `6.6`
- `6.12`

Other kernel lines fail fast instead of silently writing unsafe configuration.

## What It Does

`setup.sh` detects the target kernel from `$KERNEL_ROOT/common/Makefile` and then:

- downloads the required DroidSpaces GKI kABI patch from the upstream repository;
- applies the patch under `$KERNEL_ROOT/common`;
- applies the extra POSIX mqueue kABI patch on `5.10`;
- updates `$DEFCONFIG` one option at a time, replacing `# CONFIG_x is not set` when present and appending missing options.

The enabled config symbols are:

```makefile
CONFIG_SYSVIPC=y
CONFIG_POSIX_MQUEUE=y
CONFIG_IPC_NS=y
CONFIG_PID_NS=y
CONFIG_DEVTMPFS=y
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
CONFIG_NETFILTER_XT_TARGET_REJECT=y
CONFIG_NETFILTER_XT_TARGET_LOG=y
CONFIG_NETFILTER_XT_MATCH_RECENT=y
CONFIG_IP_SET=y
CONFIG_IP_SET_HASH_IP=y
CONFIG_IP_SET_HASH_NET=y
CONFIG_NETFILTER_XT_SET=y
```

Patch application is strict: if a required patch cannot apply and is not already applied, the build fails.

## Verification

After flashing the built kernel, verify from DroidSpaces:

```sh
su -c droidspaces check
```

or use the app requirements checker in DroidSpaces settings.
