#!/usr/bin/env bash
# Fetch the kernel source tree.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKSPACE=${WORKSPACE:?WORKSPACE must be set}
KERNEL_DIR="${WORKSPACE}/android-kernel"

group "Cloning kernel source"
info "${KERNEL_SOURCE} @ ${KERNEL_SOURCE_BRANCH}"

ref_exists "$KERNEL_SOURCE" "$KERNEL_SOURCE_BRANCH" \
	|| die "branch/tag '${KERNEL_SOURCE_BRANCH}' does not exist in ${KERNEL_SOURCE}"

rm -rf "$KERNEL_DIR"
retry 3 git clone -q --recursive --depth=1 \
	-b "$KERNEL_SOURCE_BRANCH" "$KERNEL_SOURCE" "$KERNEL_DIR" \
	|| die "failed to clone ${KERNEL_SOURCE}"

# --- OnePlus/OPPO: 主仓库缺 vendor/ 与 techpack，需从 modules 仓库补齐 ---
MODULES_SOURCE="${MODULES_SOURCE:-https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8350}"
MODULES_BRANCH="${MODULES_BRANCH:-$KERNEL_SOURCE_BRANCH}"
case "$KERNEL_SOURCE" in
*neplus*|*oplus*|*oppo*|*OnePlus*)
	info "overlaying OPPO vendor tree: ${MODULES_SOURCE} @ ${MODULES_BRANCH}"
	MOD_DIR="${WORKSPACE}/oplus-modules"
	rm -rf "$MOD_DIR"
	if retry 3 git clone -q --depth=1 -b "$MODULES_BRANCH" "$MODULES_SOURCE" "$MOD_DIR"; then
		mkdir -p "${KERNEL_DIR}/vendor"
		[ -d "$MOD_DIR/vendor" ] && cp -a "$MOD_DIR/vendor/." "${KERNEL_DIR}/vendor/"
		# 注意：不拷贝 techpack，其子 Makefile 依赖 OPPO 内部布局，直接并入会导致子 make 失败
		# 树内存在指向 ../../../vendor/oplus/... 的符号链接（会跳出树外），
		# 用 modules 仓库的实体目录替换，避免 Kconfig 打不开
		fixed=0; failed=0; miss=0
		while IFS= read -r l; do
			tgt=$(readlink "$l" 2>/dev/null) || continue
			case "$tgt" in
			*vendor/oplus/*)
				rel=${tgt##*vendor/}
				src_path="$MOD_DIR/vendor/$rel"
				if [ -e "$src_path" ]; then
					rm -rf "$l"
					if cp -a --remove-destination "$src_path" "$l" 2>/dev/null; then
						fixed=$((fixed + 1))
					else
						warn "failed to materialise ${l} from ${src_path}"
						failed=$((failed + 1))
					fi
				else
					miss=$((miss + 1))
				fi
				;;
			esac
		done < <(find "${KERNEL_DIR}" -type l 2>/dev/null)
		ok "vendor overlay applied (repaired: ${fixed}, failed: ${failed}, target-missing: ${miss})"
	else
		warn "modules repo clone failed; vendor overlay skipped"
	fi
	;;
esac

# KernelSU forks compute their version from the commit count, and several
# read it straight out of the enclosing git repo. A depth-1 clone reports 1
# commit, which produces a nonsense version. Unshallow just enough to count.
if [ -f "${KERNEL_DIR}/.git/shallow" ]; then
	debug "kernel tree is shallow; that is fine for building"
fi

KVER=$(kernel_version "$KERNEL_DIR") \
	|| die "could not read VERSION/PATCHLEVEL from ${KERNEL_DIR}/Makefile -- is this a kernel tree?"
export_env KERNEL_VERSION "$KVER"
export_env KERNEL_DIR "$KERNEL_DIR"
ok "kernel source ready (Linux ${KVER})"
summary "| Kernel | \`${KERNEL_SOURCE##*/}\` @ \`${KERNEL_SOURCE_BRANCH}\` (Linux ${KVER}) |"

# LOCALVERSION is used purely to decorate artifact names.
if is_true "${ADD_LOCALVERSION_TO_FILENAME:-false}" && [ -f "${KERNEL_DIR}/localversion" ]; then
	export_env LOCALVERSION "$(cat "${KERNEL_DIR}/localversion")"
else
	export_env LOCALVERSION ""
fi
endgroup
