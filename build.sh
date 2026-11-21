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
# Every link the build makes is recorded in a linker map (SOND_CC is a wrapper
# adding -Wl,-Map; autoconf's conftest links are left out). A dependency whose
# archive the linker pulled in is `bundled` with its version and licence, and
# musl with it; one only included is not.
#
# Licence opinion (dictamen-licencias-paquetes-distro-sond.md, section 3): when
# the licence is copyleft or Apache-2.0, the upstream must be a commit and every
# file the fork touches must carry "Modified by the Sond project, YYYY-MM-DD"; a
# GPL fork may not carry Sond's Apache-2.0 header. When the licence or a bundled
# component is copyleft, the corresponding source is built as <name>-source
# (the fork at its commit, the patches since upstream, the build recipe, musl's
# source and every bundled component's source, cloned from SOND_GIT_BASE,
# default https://) and the package names it in source_object.
#
# Environment: SOND_WORK (scratch, default $RUNNER_TEMP/sond or a temp dir),
# SOND_DISTRO_PKG (a sond-distro-pkg checkout; cloned from GitHub without it).
# Prints source_bundle=<path> (source lane only), bundle=<path> and
# payload_hash=<sha256> on success.

set -euo pipefail

usage() {
	sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
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

sondpkg() { python3 "$distro/sondpkg/bin/sondpkg" "$@"; }

# What the licence opinion asks of the fork before anything is built.
lane_rc=0
sondpkg needs-source "$license" >/dev/null || lane_rc=$?
[ "$lane_rc" -le 1 ] || exit 2
if [ "$lane_rc" = 0 ] || grep -qw 'Apache-2\.0' <<<"$license"; then
	upstream_sha=${upstream##*@}
	sondpkg check-change-marks "$fork" "$upstream_sha" >&2
	if grep -q 'GPL-' <<<"$license" &&
		git -C "$fork" diff "$upstream_sha" HEAD | grep -qE '^\+.*(SPDX-License-Identifier: Apache-2\.0|Licensed under the Apache License)'; then
		printf 'build.sh: a GPL fork may not carry the Apache-2.0 header (licence opinion, section 3 step 7)\n' >&2
		exit 1
	fi
fi

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

# SOND_CC records every real link in a map under $maps.
maps=$work/link-maps
mkdir -p "$maps" "$work/bin"
cat >"$work/bin/sond-cc" <<WRAP
#!/bin/sh
link=1 out=a.out prev=
for a in "\$@"; do
	case \$a in -c|-E|-S|-M|-MM|-dump*|-print-*|--version|-v|-V|--help) link=0 ;; esac
	[ "\$prev" = -o ] && out=\$a
	prev=\$a
done
case \$(basename "\$out") in conftest*) link=0 ;; esac
[ \$link = 1 ] && exec "$PREFIX/bin/musl-gcc" "\$@" -Wl,-Map="\$(mktemp "$maps/map.XXXXXX")"
exec "$PREFIX/bin/musl-gcc" "\$@"
WRAP
chmod +x "$work/bin/sond-cc"
SOND_CC=$work/bin/sond-cc
SOND_CFLAGS=$(repro_cflags "$fork")
SOND_LDFLAGS=$(repro_ldflags)

# Dependencies: published packages, checked under the pinned log key, in a sysroot.
registry=${SOND_REGISTRY_URL:-https://dist.sond.dev}
log_key=${SOND_LOG_KEY:-072f2d42e0c81e0d075a50585e63bfbe74f2f8d65a0d6db2c1185f432d5a44e8}
SOND_SYSROOT=$work/sysroot
dep_names=()
declare -A dep_version_of=() dep_license_of=() dep_source_of=() dep_archives_of=()
for dep in "${depends[@]}"; do
	read -r dep_name dep_version extra <<<"$dep"
	if [ -z "$dep_version" ] || [ -n "$extra" ]; then
		printf 'build.sh: --depends wants "NAME VERSION", got "%s"\n' "$dep" >&2
		exit 2
	fi
	before=$({ find "$SOND_SYSROOT" -name '*.a' 2>/dev/null || true; } | sort)
	fetched=$(sondpkg fetch "$dep_name" "$dep_version" \
		--url "$registry" --log-key "$log_key" --into "$SOND_SYSROOT")
	printf '%s\n' "$fetched" >&2
	after=$({ find "$SOND_SYSROOT" -name '*.a' 2>/dev/null || true; } | sort)
	dep_names+=("$dep_name")
	dep_version_of[$dep_name]=$dep_version
	dep_license_of[$dep_name]=$(sed -n 's/^license=//p' <<<"$fetched")
	dep_source_of[$dep_name]=$(sed -n 's/^source=//p' <<<"$fetched")
	dep_archives_of[$dep_name]=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed '/^$/d')
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

# bundled: the archives the linker pulled in, as recorded in the maps.
if [ ${#depends[@]} -gt 0 ] && ! compgen -G "$maps/map.*" >/dev/null; then
	printf 'build.sh: --depends given but no link went through $SOND_CC, so what is bundled cannot be known; link with $SOND_CC\n' >&2
	exit 1
fi
linked=$({ cat "$maps"/map.* 2>/dev/null || true; } | sed -n 's|^\(/[^ (]*\.a\)(.*|\1|p' | xargs -r realpath -m | sort -u)
bundled=()
for dep_name in "${dep_names[@]}"; do
	while IFS= read -r archive; do
		if [ -n "$archive" ] && grep -qxF "$archive" <<<"$linked"; then
			bundled+=("$dep_name ${dep_version_of[$dep_name]} ${dep_license_of[$dep_name]}")
			break
		fi
	done <<<"${dep_archives_of[$dep_name]}"
done
[ ${#bundled[@]} -eq 0 ] || bundled+=("musl ${MUSL_TAG#v} MIT")

# Licence files: the fork's, each linked dependency's and musl's, as (source, path in payload).
licence_src=() licence_dest=()
for spec in "${license_files[@]}"; do
	file=${spec%%=*}
	dest=share/licenses/$name/$(basename "$file")
	[ "$spec" != "$file" ] && dest=${spec#*=}
	licence_src+=("$fork/$file") licence_dest+=("$dest")
done
# A dependency is linked in statically: its licences ship inside this package.
for dep_name in "${dep_names[@]}"; do
	for f in "$SOND_SYSROOT/share/licenses/$dep_name"/*; do
		[ -f "$f" ] && licence_src+=("$f") licence_dest+=("share/licenses/$name/$dep_name-$(basename "$f")")
	done
done
# A package whose linkage names musl links it statically, and musl's COPYRIGHT must ship
# inside it; a package with no binary (headers) names no musl and carries none.
links_musl=0
case $linkage in *musl*) links_musl=1 ;; esac
[ "$links_musl" = 0 ] || licence_src+=("$SRC_ROOT/musl-sond/COPYRIGHT") licence_dest+=("share/licenses/$name/musl-COPYRIGHT")

lane_args=("$license")
for b in "${bundled[@]}"; do lane_args+=(--bundled "$b"); done
lane_rc=0
sondpkg needs-source "${lane_args[@]}" >/dev/null || lane_rc=$?
[ "$lane_rc" -le 1 ] || exit 2

source_object=
if [ "$lane_rc" = 0 ]; then
	# The corresponding source, published first as <name>-source.
	tree=$work/source-payload/$name-source
	share=$tree/share/src/$name
	mkdir -p "$share/patches"
	cp "$tarball" "$share/"
	upstream_sha=${upstream##*@}
	git -C "$fork" format-patch -q --no-signature --no-stat -o "$share/patches" "$upstream_sha..$sha" >/dev/null
	if [ "$links_musl" = 1 ]; then
		git -C "$SRC_ROOT/musl-sond" archive --format=tar --prefix="musl-${MUSL_TAG#v}/" "$MUSL_COMMIT" |
			gzip -n >"$share/musl-${MUSL_TAG#v}.tar.gz"
	fi
	git_base=${SOND_GIT_BASE:-https://}
	for b in "${bundled[@]}"; do
		read -r b_name b_version _ <<<"$b"
		[ "$b_name" = musl ] && continue
		b_source=${dep_source_of[$b_name]}
		b_repo=${b_source%@*} b_sha=${b_source##*@}
		clone=$work/dep-src/$b_name
		[ -d "$clone/.git" ] || git clone -q --no-checkout --filter=blob:none "$git_base$b_repo" "$clone" 2>/dev/null ||
			git clone -q --no-checkout "$git_base$b_repo" "$clone" >&2
		git -C "$clone" archive --format=tar --prefix="$b_name-$b_version/" "$b_sha" |
			gzip -n >"$share/$b_name-$b_version.tar.gz"
	done
	{
		printf '#!/bin/sh\n# How %s %s was built from this source (sond-build-action).\n' "$name" "$version"
		printf '# Fork: github.com/%s@%s; upstream: %s\n' "$repository" "$sha" "$upstream"
		[ "$links_musl" = 0 ] || printf '# Toolchain: musl %s (musl-%s.tar.gz, commit %s), static.\n' "${MUSL_TAG#v}" "${MUSL_TAG#v}" "$MUSL_COMMIT"
		printf '# SOND_CC: musl-gcc; SOND_CFLAGS: %s; SOND_LDFLAGS: %s\n' "$(repro_cflags '$SRC')" "$(repro_ldflags)"
		for dep in "${depends[@]}"; do printf '# Depends: %s, installed into $SOND_SYSROOT (-I$SOND_SYSROOT/include -L$SOND_SYSROOT/lib)\n' "$dep"; done
		printf '# The build command, run in the fork with $SOND_PAYLOAD as the install root:\n%s\n' "$build"
	} >"$share/build-recipe.sh"
	src_args=(build-bundle --name "$name-source" --version "$version" --license "$license"
		--source "github.com/$repository@$sha" --upstream "$upstream"
		--linkage source --tier "$tier" --tree "$tree" --source-file "$tarball" --out "$out")
	for i in "${!licence_src[@]}"; do
		src_args+=(--license-file "${licence_src[$i]}=${licence_dest[$i]/#share\/licenses\/$name\//share/licenses/$name-source/}")
	done
	source_bundle=$(sondpkg "${src_args[@]}" | tail -n1)
	sondpkg verify-bundle "$source_bundle" >/dev/null
	source_object=$(sondpkg object-id "$source_bundle")
fi

args=(build-bundle --name "$name" --version "$version" --license "$license"
	--source "github.com/$repository@$sha" --upstream "$upstream"
	--linkage "$linkage" --tier "$tier" --tree "$payload"
	--source-file "$tarball" --out "$out")
for i in "${!licence_src[@]}"; do args+=(--license-file "${licence_src[$i]}=${licence_dest[$i]}"); done
for b in "${bundled[@]}"; do args+=(--bundled "$b"); done
[ -z "$source_object" ] || args+=(--source-object "$source_object")

bundle=$(sondpkg "${args[@]}" | tail -n1)
sondpkg verify-bundle "$bundle" >/dev/null
hash=$(sondpkg show "$bundle" | sed -n 's/^bundle = //p' | head -n1)

[ -z "$source_object" ] || printf 'source_bundle=%s\n' "$source_bundle"
printf 'bundle=%s\n' "$bundle"
printf 'payload_hash=%s\n' "$hash"
