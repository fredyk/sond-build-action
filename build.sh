#!/bin/bash
# Build a Sond package from a fork checkout and leave a verified RFC-0018
# bundle. The fork's own build command compiles with the pinned musl toolchain
# (SOND_CC, SOND_CFLAGS, SOND_LDFLAGS, SOURCE_DATE_EPOCH) and installs into
# $SOND_PAYLOAD; this script then records the fork's commit, its upstream, its
# licence files and its source tarball in the bundle's MANIFEST.
#
# usage: build.sh --fork DIR --repository OWNER/REPO --name N --version V
#                 --license SPDX --upstream HOST/OWNER/REPO@SHA40 --build CMD
#                 [--license-file PATH[=DEST]]... [--linkage TEXT] [--tier T]
#                 [--depends "NAME VERSION"]... --out DIR
#
# Each --depends package is fetched from the registry (SOND_REGISTRY_URL, default
# https://dist.sond.dev) with `sondpkg fetch`, checked under the pinned log key
# (SOND_LOG_KEY), into the sysroot $SOND_SYSROOT; the build compiles against it
# (-I and -L in SOND_CFLAGS and SOND_LDFLAGS, PKG_CONFIG_LIBDIR and
# PKG_CONFIG_SYSROOT_DIR) and the package ships each dependency's licences.
#
# Environment: SOND_WORK (scratch, default $RUNNER_TEMP/sond or a temp dir),
# SOND_DISTRO_PKG (a sond-distro-pkg checkout; cloned from GitHub without it).
# Prints bundle=<path> and payload_hash=<sha256> on success.

set -euo pipefail

usage() {
	sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
	exit 2
}

fork= repository= name= version= license= upstream= build= out=
linkage="static musl 1.2.5 (MIT)"
tier=public
license_files=()
depends=()
while [ $# -gt 0 ]; do
	case $1 in
	--fork) fork=$2 ;;
	--repository) repository=$2 ;;
	--name) name=$2 ;;
	--version) version=$2 ;;
	--license) license=$2 ;;
	--upstream) upstream=$2 ;;
	--build) build=$2 ;;
	--license-file) license_files+=("$2") ;;
	--linkage) linkage=$2 ;;
	--tier) tier=$2 ;;
	--depends) depends+=("$2") ;;
	--out) out=$2 ;;
	*) usage ;;
	esac
	shift 2 || usage
done
for v in fork repository name version license upstream build out; do
	[ -n "${!v}" ] || { printf 'build.sh: --%s is required\n' "$v" >&2; usage; }
done
fork=$(cd "$fork" && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)

work=${SOND_WORK:-${RUNNER_TEMP:+$RUNNER_TEMP/sond}}
[ -n "$work" ] || work=$(mktemp -d)
mkdir -p "$work"
work=$(cd "$work" && pwd)

# The packager and the toolchain recipe come from sond-distro-pkg.
distro=${SOND_DISTRO_PKG:-}
if [ -z "$distro" ]; then
	distro=$work/sond-distro-pkg
	[ -d "$distro/.git" ] || git clone -q --depth 1 https://github.com/fredyk/sond-distro-pkg "$distro" >&2
fi
distro=$(cd "$distro" && pwd)

# The pinned musl toolchain, built once per scratch dir from its fork.
export SOND_FORKS=$work/forks TOOLCHAIN_WORK=$work/tc
# shellcheck source=/dev/null
. "$distro/toolchain/common.sh"
# The fork checkout is needed even when the prefix comes from a cache: musl's
# COPYRIGHT ships in every package.
[ -d "$SRC_ROOT/musl-sond/.git" ] ||
	git clone -q --branch "$MUSL_TAG" "$MUSL_URL" "$SRC_ROOT/musl-sond" >&2
if [ ! -x "$PREFIX/bin/musl-gcc" ]; then
	bash "$distro/toolchain/build-musl.sh" >"$work/musl-build.log" 2>&1 ||
		{ tail -30 "$work/musl-build.log" >&2; exit 1; }
fi

payload=$work/payload/$name
if [ -e "$payload" ]; then
	printf 'build.sh: %s already exists; give a fresh SOND_WORK\n' "$payload" >&2
	exit 1
fi
mkdir -p "$payload"

SOND_CC=$PREFIX/bin/musl-gcc
SOND_CFLAGS=$(repro_cflags "$fork")
SOND_LDFLAGS=$(repro_ldflags)

# Dependencies: published packages, checked under the pinned log key, in a sysroot.
registry=${SOND_REGISTRY_URL:-https://dist.sond.dev}
log_key=${SOND_LOG_KEY:-072f2d42e0c81e0d075a50585e63bfbe74f2f8d65a0d6db2c1185f432d5a44e8}
SOND_SYSROOT=$work/sysroot
dep_names=()
for dep in "${depends[@]}"; do
	read -r dep_name dep_version extra <<<"$dep"
	if [ -z "$dep_version" ] || [ -n "$extra" ]; then
		printf 'build.sh: --depends wants "NAME VERSION", got "%s"\n' "$dep" >&2
		exit 2
	fi
	python3 "$distro/sondpkg/bin/sondpkg" fetch "$dep_name" "$dep_version" \
		--url "$registry" --log-key "$log_key" --into "$SOND_SYSROOT" >&2
	dep_names+=("$dep_name")
done
if [ ${#depends[@]} -gt 0 ]; then
	SOND_CFLAGS="$SOND_CFLAGS -I$SOND_SYSROOT/include"
	SOND_LDFLAGS="$SOND_LDFLAGS -L$SOND_SYSROOT/lib"
	export PKG_CONFIG_LIBDIR=$SOND_SYSROOT/lib/pkgconfig PKG_CONFIG_SYSROOT_DIR=$SOND_SYSROOT
fi
export SOND_CC SOND_CFLAGS SOND_LDFLAGS SOND_SYSROOT SOND_PAYLOAD=$payload SOURCE_DATE_EPOCH
# stdout carries only the results below; the build's own output goes to stderr.
(cd "$fork" && bash -euo pipefail -c "$build") >&2

sha=$(git -C "$fork" rev-parse HEAD)
srcdir=$work/src
mkdir -p "$srcdir"
tarball=$srcdir/$name-$version.tar.gz
git -C "$fork" archive --format=tar --prefix="$name-$version/" "$sha" | gzip -n >"$tarball"

args=(build-bundle --name "$name" --version "$version" --license "$license"
	--source "github.com/$repository@$sha" --upstream "$upstream"
	--linkage "$linkage" --tier "$tier" --tree "$payload"
	--source-file "$tarball" --out "$out")
for spec in "${license_files[@]}"; do
	file=${spec%%=*}
	dest=
	[ "$spec" != "$file" ] && dest="=${spec#*=}"
	args+=(--license-file "$fork/$file$dest")
done

# A dependency is linked in statically: its licences ship inside this package.
for dep_name in "${dep_names[@]}"; do
	for f in "$SOND_SYSROOT/share/licenses/$dep_name"/*; do
		[ -f "$f" ] && args+=(--license-file "$f=share/licenses/$name/$dep_name-$(basename "$f")")
	done
done

# Every package links musl statically, and musl's COPYRIGHT must ship inside it.
args+=(--license-file "$SRC_ROOT/musl-sond/COPYRIGHT=share/licenses/$name/musl-COPYRIGHT")

bundle=$(python3 "$distro/sondpkg/bin/sondpkg" "${args[@]}" | tail -n1)
python3 "$distro/sondpkg/bin/sondpkg" verify-bundle "$bundle" >/dev/null
hash=$(python3 "$distro/sondpkg/bin/sondpkg" show "$bundle" | sed -n 's/^bundle = //p' | head -n1)

printf 'bundle=%s\n' "$bundle"
printf 'payload_hash=%s\n' "$hash"
