#!/bin/bash
# build.sh turns a fork checkout into a verified RFC-0018 bundle: the fork's
# build command installs a static musl binary into $SOND_PAYLOAD, and build.sh
# records the fork's commit, the upstream, the licence and the source tarball.
#
# usage: test-build.sh   (clones fredyk/musl-sond and fredyk/sond-distro-pkg)
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

# A toy fork: one C file, its licence, a build command, one commit.
fork=$work/hello-sond
mkdir -p "$fork"
cat >"$fork/hello.c" <<'C'
#include <stdio.h>
int main(void) { puts("hello-sond-ok"); return 0; }
C
printf 'Zero-Clause BSD\n' >"$fork/LICENSE"
git -C "$fork" init -q -b sond
git -C "$fork" -c user.name=t -c user.email=t@t add -A
git -C "$fork" -c user.name=t -c user.email=t@t commit -q -m hello
sha=$(git -C "$fork" rev-parse HEAD)

out=$work/out
SOND_WORK=$work/w \
SOND_DISTRO_PKG=${SOND_DISTRO_PKG:-} \
	bash "$here/build.sh" \
	--fork "$fork" --repository fredyk/hello-sond \
	--name hello --version 1.0 --license 0BSD \
	--upstream github.com/example/hello@0000000000000000000000000000000000000000 \
	--license-file LICENSE \
	--build 'echo bundle=noise-from-the-build; mkdir -p "$SOND_PAYLOAD/bin" && $SOND_CC $SOND_CFLAGS -static $SOND_LDFLAGS -o "$SOND_PAYLOAD/bin/hello" hello.c' \
	--out "$out" >"$work/build.log" 2>"$work/build.err"
rc=$?
[ "$rc" = 0 ] && ok "build.sh succeeds" || { bad "build.sh succeeds (rc=$rc)"; tail -20 "$work/build.err"; }

bundle=$(ls -d "$out"/hello-1.0-* 2>/dev/null | head -n1)
[ -n "$bundle" ] && [ -f "$bundle/MANIFEST" ] && ok "a bundle hello-1.0-<H12> with its MANIFEST" || bad "a bundle hello-1.0-<H12> with its MANIFEST"
bin=$bundle/payload/bin/hello
case $(file -b "$bin" 2>/dev/null) in
*"statically linked"*) ok "the payload binary is static" ;;
*) bad "the payload binary is static ($(file -b "$bin" 2>&1))" ;;
esac
[ "$("$bin" 2>/dev/null)" = "hello-sond-ok" ] && ok "the payload binary runs" || bad "the payload binary runs"
[ -f "$bundle/payload/share/licenses/hello/LICENSE" ] && ok "the licence ships in the payload" || bad "the licence ships in the payload"
[ -f "$bundle/payload/share/licenses/hello/musl-COPYRIGHT" ] && ok "musl COPYRIGHT ships in the payload" || bad "musl COPYRIGHT ships in the payload"
grep -q "github.com/fredyk/hello-sond@$sha" "$bundle/MANIFEST" && ok "the manifest names the fork commit" || bad "the manifest names the fork commit"
grep -q 'hello-1.0.tar.gz' "$bundle/MANIFEST" && ok "the manifest records the source tarball by hash" || bad "the manifest records the source tarball by hash"
grep -qx "bundle=$bundle" "$work/build.log" && ok "build.sh prints bundle=<path> for the action output" || bad "build.sh prints bundle=<path> for the action output"

grep -qE "^payload_hash=.*[0-9a-f]{64}" "$work/build.log" && ok "build.sh prints payload_hash=<the bundle hash>" || bad "build.sh prints payload_hash=<the bundle hash> ($(grep ^payload_hash= "$work/build.log"))"
[ "$(grep -c . "$work/build.log")" = 2 ] && ok "stdout holds only bundle= and payload_hash= (the build's own output goes to stderr)" || bad "stdout holds only bundle= and payload_hash= ($(cat "$work/build.log"))"

# A restored cache brings back only the musl prefix: the next build reuses it
# without rebuilding musl and still finds musl's COPYRIGHT.
mkdir -p "$work/w2/forks"
cp -a "$work/w/forks/toolchain" "$work/w2/forks/"
SOND_WORK=$work/w2 \
SOND_DISTRO_PKG=${SOND_DISTRO_PKG:-} \
	bash "$here/build.sh" \
	--fork "$fork" --repository fredyk/hello-sond \
	--name hello --version 1.0 --license 0BSD \
	--upstream github.com/example/hello@0000000000000000000000000000000000000000 \
	--license-file LICENSE \
	--build 'mkdir -p "$SOND_PAYLOAD/bin" && $SOND_CC $SOND_CFLAGS -static $SOND_LDFLAGS -o "$SOND_PAYLOAD/bin/hello" hello.c' \
	--out "$work/out2" >"$work/build2.log" 2>&1
rc=$?
[ "$rc" = 0 ] && ok "a build with only the musl prefix restored succeeds" || { bad "a build with only the musl prefix restored succeeds (rc=$rc)"; tail -20 "$work/build2.log"; }
[ ! -e "$work/w2/musl-build.log" ] && ok "a restored musl prefix is not rebuilt" || bad "a restored musl prefix is not rebuilt"

# A dependency: --depends NAME VERSION fetches the published package into a sysroot the build
# compiles against, and its licences ship in the package. `sondpkg fetch` (tested in
# sond-distro-pkg) is replaced by a fake that records its arguments and installs a header.
distro=$work/distro
if [ -n "${SOND_DISTRO_PKG:-}" ]; then cp -a "$SOND_DISTRO_PKG" "$distro"; else git clone -q --depth 1 https://github.com/fredyk/sond-distro-pkg "$distro"; fi
mv "$distro/sondpkg/bin/sondpkg" "$distro/sondpkg/bin/sondpkg.real"
cat >"$distro/sondpkg/bin/sondpkg" <<'PY'
import os, subprocess, sys
here = os.path.dirname(os.path.abspath(__file__))
if sys.argv[1] != "fetch":
    sys.exit(subprocess.call([sys.executable, os.path.join(here, "sondpkg.real")] + sys.argv[1:]))
with open(os.environ["FAKE_FETCH_LOG"], "a") as log:
    log.write(" ".join(sys.argv[1:]) + "\n")
into = sys.argv[sys.argv.index("--into") + 1]
os.makedirs(os.path.join(into, "include"), exist_ok=True)
with open(os.path.join(into, "include", "greet.h"), "w") as h:
    h.write('#define GREETING "hi-from-%s"\n' % sys.argv[2])
os.makedirs(os.path.join(into, "share", "licenses", sys.argv[2]), exist_ok=True)
with open(os.path.join(into, "share", "licenses", sys.argv[2], "COPYING"), "w") as h:
    h.write("greet licence\n")
if sys.argv[2] == "linux-headers":
    os.makedirs(os.path.join(into, "include", "linux"), exist_ok=True)
    with open(os.path.join(into, "include", "linux", "note.h"), "w") as h:
        h.write("/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */\n#define NOTE_X 1\n")
    with open(os.path.join(into, "include", "linux", "perm.h"), "w") as h:
        h.write("/* SPDX-License-Identifier: MIT */\n/* Copyright perm authors */\n#define PERM_X 2\n")
lib = os.environ.get("FAKE_LIB")
if lib:
    import shutil
    os.makedirs(os.path.join(into, "lib"), exist_ok=True)
    shutil.copy(lib, os.path.join(into, "lib", "libgreet.a"))
print("object=sha256:" + "0" * 64)
print("license=MIT")
print("source=" + os.environ.get("FAKE_SOURCE", "github.com/fredyk/greet-sond@" + "1" * 40))
PY
cat >"$fork/greet.c" <<'C'
#include <stdio.h>
#include <greet.h>
int main(void) { puts(GREETING); return 0; }
C
mkdir -p "$work/w3/forks"
cp -a "$work/w/forks/toolchain" "$work/w3/forks/"
FAKE_FETCH_LOG=$work/fetch.log SOND_WORK=$work/w3 SOND_DISTRO_PKG=$distro \
	bash "$here/build.sh" \
	--fork "$fork" --repository fredyk/hello-sond \
	--name hello --version 1.1 --license 0BSD \
	--upstream github.com/example/hello@0000000000000000000000000000000000000000 \
	--license-file LICENSE --depends "greet 2.0" \
	--build 'mkdir -p "$SOND_PAYLOAD/bin" && $SOND_CC $SOND_CFLAGS -static $SOND_LDFLAGS -o "$SOND_PAYLOAD/bin/hello" greet.c' \
	--out "$work/out3" >"$work/build3.log" 2>"$work/build3.err"
rc=$?
[ "$rc" = 0 ] && ok "a build with a dependency succeeds" || { bad "a build with a dependency succeeds (rc=$rc)"; tail -20 "$work/build3.err"; }
grep -qx "fetch greet 2.0 --url https://dist.sond.dev --log-key 072f2d42e0c81e0d075a50585e63bfbe74f2f8d65a0d6db2c1185f432d5a44e8 --into $work/w3/sysroot" "$work/fetch.log" &&
	ok "the dependency is fetched from dist.sond.dev under its pinned log key" || bad "the dependency is fetched from dist.sond.dev under its pinned log key ($(cat "$work/fetch.log" 2>&1))"
b3=$(ls -d "$work/out3"/hello-1.1-* 2>/dev/null | head -n1)
[ "$("$b3/payload/bin/hello" 2>/dev/null)" = "hi-from-greet" ] && ok "the build compiles against the sysroot" || bad "the build compiles against the sysroot"
[ -f "$b3/payload/share/licenses/hello/greet-COPYING" ] && ok "the dependency's licence ships in the package" || bad "the dependency's licence ships in the package"
[ ! -e "$b3/payload/include/greet.h" ] && ok "the sysroot itself is not packaged" || bad "the sysroot itself is not packaged"

grep -q '^bundled' "$b3/MANIFEST" && bad "a dependency only included, never linked, is not bundled" || ok "a dependency only included, never linked, is not bundled"

# bundled comes from the link maps: a dependency whose archive the linker pulled in is recorded
# with its version and licence, and musl with it.
musl_gcc=$(find "$work/w/forks/toolchain" -name musl-gcc -path '*/bin/*' | head -n1)
mkdir -p "$work/lib"
printf 'const char *greeting(void) { return "linked-greet"; }\n' >"$work/lib/greet.c"
"$musl_gcc" -Os -c -o "$work/lib/greet.o" "$work/lib/greet.c" && ar rcs "$work/lib/libgreet.a" "$work/lib/greet.o"
cat >"$fork/linked.c" <<'C'
#include <stdio.h>
const char *greeting(void);
int main(void) { puts(greeting()); return 0; }
C
newws() { mkdir -p "$work/$1/forks"; cp -a "$work/w/forks/toolchain" "$work/$1/forks/"; }
newws w4
FAKE_LIB=$work/lib/libgreet.a FAKE_FETCH_LOG=$work/fetch.log SOND_WORK=$work/w4 SOND_DISTRO_PKG=$distro \
	bash "$here/build.sh" \
	--fork "$fork" --repository fredyk/hello-sond \
	--name hello --version 1.3 --license 0BSD \
	--upstream github.com/example/hello@0000000000000000000000000000000000000000 \
	--license-file LICENSE --depends "greet 2.0" \
	--build 'probe() { $SOND_CC $SOND_CFLAGS -static $SOND_LDFLAGS -o conftest linked.c -lgreet; }; probe; mkdir -p "$SOND_PAYLOAD/bin" && $SOND_CC $SOND_CFLAGS -c -o linked.o linked.c && $SOND_CC $SOND_CFLAGS -static $SOND_LDFLAGS -o "$SOND_PAYLOAD/bin/hello" linked.o -lgreet; rm -f conftest linked.o' \
	--out "$work/out4" >"$work/build4.log" 2>"$work/build4.err"
rc=$?
[ "$rc" = 0 ] && ok "a build linking a dependency succeeds" || { bad "a build linking a dependency succeeds (rc=$rc)"; tail -20 "$work/build4.err"; }
b4=$(ls -d "$work/out4"/hello-1.3-* 2>/dev/null | head -n1)
[ "$("$b4/payload/bin/hello" 2>/dev/null)" = "linked-greet" ] && ok "the linked binary runs" || bad "the linked binary runs"
grep -q '"greet 2.0 MIT"' "$b4/MANIFEST" && ok "the linked dependency is bundled with its version and licence" || bad "the linked dependency is bundled ($(grep -A3 bundled "$b4/MANIFEST" 2>&1))"
grep -q '"musl 1.2.5 MIT"' "$b4/MANIFEST" && ok "musl is bundled with it" || bad "musl is bundled with it"
[ "$(grep -c . "$work/build4.log")" = 2 ] && ok "a permissive package has no source bundle" || bad "a permissive package has no source bundle ($(cat "$work/build4.log"))"

# A build that links nothing through SOND_CC still packages (its bundled stays empty)...
newws w4b
SOND_WORK=$work/w4b SOND_DISTRO_PKG=$distro bash "$here/build.sh" \
	--fork "$fork" --repository fredyk/hello-sond --name hello --version 1.4 --license 0BSD \
	--upstream github.com/example/hello@0000000000000000000000000000000000000000 --license-file LICENSE \
	--build 'mkdir -p "$SOND_PAYLOAD/bin" && cp LICENSE "$SOND_PAYLOAD/bin/hello"' \
	--out "$work/out4b" >"$work/build4b.log" 2>"$work/build4b.err"
rc=$?
[ "$rc" = 0 ] && ok "a build with no link through SOND_CC succeeds" || { bad "a build with no link through SOND_CC succeeds (rc=$rc)"; tail -5 "$work/build4b.err"; }
# ...but with a dependency declared, links the maps cannot see would hide what is bundled.
newws w4c
FAKE_LIB=$work/lib/libgreet.a FAKE_FETCH_LOG=$work/fetch.log SOND_WORK=$work/w4c SOND_DISTRO_PKG=$distro bash "$here/build.sh" \
	--fork "$fork" --repository fredyk/hello-sond --name hello --version 1.5 --license 0BSD \
	--upstream github.com/example/hello@0000000000000000000000000000000000000000 --license-file LICENSE \
	--depends "greet 2.0" --build 'mkdir -p "$SOND_PAYLOAD/bin" && cp LICENSE "$SOND_PAYLOAD/bin/hello"' \
	--out "$work/out4c" >/dev/null 2>"$work/build4c.err"
rc=$?
[ "$rc" != 0 ] && grep -q "SOND_CC" "$work/build4c.err" && ok "dependencies with no link through SOND_CC are refused" || { bad "dependencies with no link through SOND_CC are refused (rc=$rc)"; tail -5 "$work/build4c.err"; }

# The GPL source lane. A fork whose upstream commit is in its history, a marked change, the
# corresponding source published as <name>-source: the fork at its commit, the patches since
# upstream, the build recipe, musl's source and every bundled component's source.
gpl=$work/gpl-sond
mkdir -p "$gpl"
printf '#include <stdio.h>\nconst char *greeting(void);\nint main(void) { puts(greeting()); return 0; }\n' >"$gpl/main.c"
printf 'GNU GENERAL PUBLIC LICENSE Version 2\n' >"$gpl/COPYING"
gitc() { git -C "$1" -c user.name=t -c user.email=t@t "${@:2}"; }
git -C "$gpl" init -q -b master && gitc "$gpl" add -A && gitc "$gpl" commit -q -m upstream
upstream_sha=$(git -C "$gpl" rev-parse HEAD)
git -C "$gpl" checkout -q -b sond
printf '/* Modified by the Sond project, 2026-11-21: say it louder */\n#include <stdio.h>\nconst char *greeting(void);\nint main(void) { printf("%%s!\\n", greeting()); return 0; }\n' >"$gpl/main.c"
gitc "$gpl" commit -q -am "louder"
greet_src=$work/git/github.com/fredyk/greet-sond
mkdir -p "$greet_src" && cp "$work/lib/greet.c" "$greet_src/"
git -C "$greet_src" init -q -b sond && gitc "$greet_src" add -A && gitc "$greet_src" commit -q -m greet
greet_sha=$(git -C "$greet_src" rev-parse HEAD)
gpl_build='mkdir -p "$SOND_PAYLOAD/bin" && $SOND_CC $SOND_CFLAGS -static $SOND_LDFLAGS -o "$SOND_PAYLOAD/bin/gpl" main.c -lgreet'
gpl_args=(--repository fredyk/gpl-sond --name gpl --version 1.0 --license GPL-2.0-or-later
	--upstream "github.com/example/gpl@$upstream_sha" --license-file COPYING --depends "greet 2.0" --build "$gpl_build")
run_gpl() { # <workspace> <fork> <out> [extra...]
	newws "$1"
	FAKE_LIB=$work/lib/libgreet.a FAKE_SOURCE="github.com/fredyk/greet-sond@$greet_sha" FAKE_FETCH_LOG=$work/fetch.log \
	SOND_GIT_BASE="file://$work/git/" SOND_WORK=$work/$1 SOND_DISTRO_PKG=$distro \
		bash "$here/build.sh" --fork "$2" "${gpl_args[@]}" --out "$3" "${@:4}"
}
run_gpl w5 "$gpl" "$work/out5" >"$work/build5.log" 2>"$work/build5.err"
rc=$?
[ "$rc" = 0 ] && ok "a GPL build succeeds" || { bad "a GPL build succeeds (rc=$rc)"; tail -20 "$work/build5.err"; }
src=$(sed -n 's/^source_bundle=//p' "$work/build5.log")
b5=$(sed -n 's/^bundle=//p' "$work/build5.log")
[ "$(sed -n 1p "$work/build5.log" | cut -d= -f1)" = source_bundle ] && [ "$(grep -c . "$work/build5.log")" = 3 ] &&
	ok "stdout gives source_bundle= first, then bundle= and payload_hash=" || bad "stdout gives source_bundle= first ($(cat "$work/build5.log"))"
case $(basename "$src") in gpl-source-1.0-*) ok "the source bundle is gpl-source 1.0" ;; *) bad "the source bundle is gpl-source 1.0 ($src)" ;; esac
python3 "$distro/sondpkg/bin/sondpkg" verify-bundle "$src" >/dev/null 2>&1 && ok "the source bundle verifies" || bad "the source bundle verifies"
grep -qE '^ *linkage *= "source"$' "$src/MANIFEST" && ok "the source bundle's linkage is source" || bad "the source bundle's linkage is source"
for f in gpl-1.0.tar.gz musl-1.2.5.tar.gz greet-2.0.tar.gz build-recipe.sh; do
	[ -f "$src/payload/share/src/gpl/$f" ] && ok "the source bundle holds $f" || bad "the source bundle holds $f"
done
ls "$src/payload/share/src/gpl/patches/"0001-*.patch >/dev/null 2>&1 && ok "the source bundle holds the patches since upstream" || bad "the source bundle holds the patches since upstream"
tar -xzOf "$src/payload/share/src/gpl/greet-2.0.tar.gz" greet-2.0/greet.c 2>/dev/null | grep -q linked-greet &&
	ok "the bundled component's source is its fork at the logged commit" || bad "the bundled component's source is its fork at the logged commit"
[ -f "$src/payload/share/licenses/gpl-source/COPYING" ] && ok "the source bundle ships COPYING" || bad "the source bundle ships COPYING"
oid=$(python3 "$distro/sondpkg/bin/sondpkg" object-id "$src" 2>/dev/null)
grep -qE "^ *source_object *= \"$oid\"$" "$b5/MANIFEST" && ok "the binary names the source bundle's object" || bad "the binary names the source bundle's object ($oid)"
grep -q '"greet 2.0 MIT"' "$b5/MANIFEST" && ok "the GPL binary bundles greet" || bad "the GPL binary bundles greet"
[ "$("$b5/payload/bin/gpl" 2>/dev/null)" = "linked-greet!" ] && ok "the GPL binary runs" || bad "the GPL binary runs"
run_gpl w5b "$gpl" "$work/out5b" >"$work/build5b.log" 2>&1
[ "$(sed -n 's/^source_bundle=//p' "$work/build5b.log" | xargs basename 2>/dev/null)" = "$(basename "$src")" ] &&
	ok "the source bundle is reproducible" || bad "the source bundle is reproducible"

# What the opinion refuses before anything is built.
refuse() { # <what> <expected stderr> <fork> [extra...]
	local what=$1 expect=$2 dir=$3
	run_gpl "w-$RANDOM" "$dir" "$work/out-$RANDOM" "${@:4}" >/dev/null 2>"$work/refuse.err"
	local rc=$?
	[ "$rc" != 0 ] && grep -q "$expect" "$work/refuse.err" && ok "$what is refused" || { bad "$what is refused (rc=$rc)"; tail -5 "$work/refuse.err"; }
}
unmarked=$work/gpl-unmarked
git clone -q "$gpl" "$unmarked" && git -C "$unmarked" checkout -q sond
printf 'int extra;\n' >>"$unmarked/COPYING" && gitc "$unmarked" commit -q -am "unmarked"
refuse "a change without the notice" "Modified by the Sond project" "$unmarked"
apache=$work/gpl-apache
git clone -q "$gpl" "$apache" && git -C "$apache" checkout -q sond
printf '// SPDX-License-Identifier: Apache-2.0\n// Modified by the Sond project, 2026-11-21\nint x;\n' >"$apache/extra.c"
gitc "$apache" add -A && gitc "$apache" commit -q -m "apache header"
refuse "Sond's Apache header in a GPL fork" "Apache" "$apache"
gitc "$gpl" tag -a v1 -m v1 "$upstream_sha"
tag_object=$(git -C "$gpl" rev-parse v1)
gpl_args[9]="github.com/example/gpl@$tag_object"
refuse "an upstream that is a tag object" "not a commit" "$gpl"

# A package with no binary at all (headers): its linkage names no musl, so neither the
# payload nor the corresponding source carries musl.
hdr=$work/hdr-sond
mkdir -p "$hdr"
printf '/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */\n#define HDR 1\n' >"$hdr/hdr.h"
printf 'GNU GENERAL PUBLIC LICENSE Version 2\n' >"$hdr/COPYING"
git -C "$hdr" init -q -b sond && gitc "$hdr" add -A && gitc "$hdr" commit -q -m upstream
hdr_sha=$(git -C "$hdr" rev-parse HEAD)
SOND_WORK=$work/w7/sond RUNNER_TEMP=$work/w7 SOND_DISTRO_PKG=${SOND_DISTRO_PKG:-} \
	bash "$here/build.sh" --fork "$hdr" --repository fredyk/hdr-sond --name hdr --version 1.0 \
	--license "GPL-2.0-only WITH Linux-syscall-note" --linkage "none (headers)" \
	--upstream "github.com/example/hdr@$hdr_sha" --license-file COPYING \
	--build 'mkdir -p "$SOND_PAYLOAD/include" && cp hdr.h "$SOND_PAYLOAD/include/"' \
	--out "$work/out7" >"$work/build7.log" 2>"$work/build7.err"
rc=$?
[ "$rc" = 0 ] && ok "a headers-only build succeeds" || { bad "a headers-only build succeeds (rc=$rc)"; tail -20 "$work/build7.err"; }
b7=$(sed -n 's/^bundle=//p' "$work/build7.log")
s7=$(sed -n 's/^source_bundle=//p' "$work/build7.log")
[ -n "$b7" ] && [ ! -e "$b7/payload/share/licenses/hdr/musl-COPYRIGHT" ] &&
	ok "a headers-only payload carries no musl COPYRIGHT" || bad "a headers-only payload carries no musl COPYRIGHT"
[ -n "$s7" ] && [ -f "$s7/payload/share/src/hdr/hdr-1.0.tar.gz" ] && ! ls "$s7/payload/share/src/hdr/"musl-* >/dev/null 2>&1 &&
	ok "a headers-only source bundle holds the fork and no musl" || bad "a headers-only source bundle holds the fork and no musl"

# A binary built against linux-headers: nothing of it is bundled and the kernel's licences do
# not ship, but a used header with neither the syscall note nor the COPYING carries its notice
# (licence opinion 3.1, rule 10). The compiler's dependency files say which headers were used.
kc=$work/kc-sond
mkdir -p "$kc"
printf '#include <stdio.h>\n#include <linux/note.h>\n#include <linux/perm.h>\nint main(void) { printf("%%d\\n", NOTE_X + PERM_X); return 0; }\n' >"$kc/kc.c"
printf 'Zero-Clause BSD\n' >"$kc/LICENSE"
git -C "$kc" init -q -b sond && gitc "$kc" add -A && gitc "$kc" commit -q -m kc
run_kc() { # <workspace> <build>
	FAKE_FETCH_LOG=$work/fetch.log SOND_WORK=$work/$1/sond RUNNER_TEMP=$work/$1 SOND_DISTRO_PKG=$distro \
		bash "$here/build.sh" --fork "$kc" --repository fredyk/kc-sond --name kc --version 1.0 --license 0BSD \
		--upstream github.com/example/kc@0000000000000000000000000000000000000000 --license-file LICENSE \
		--depends "linux-headers 6.12.77" --build "$2" --out "$work/out-$1"
}
mkdir -p "$work/w8/sond/forks" "$work/w8b/sond/forks"
cp -a "$work/w/forks/toolchain" "$work/w8/sond/forks/"
cp -a "$work/w/forks/toolchain" "$work/w8b/sond/forks/"
kc_link='mkdir -p "$SOND_PAYLOAD/bin" && $SOND_CC $SOND_CFLAGS -static $SOND_LDFLAGS -o "$SOND_PAYLOAD/bin/kc" kc.o'
run_kc w8 '$SOND_CC $SOND_CFLAGS -MD -c kc.c -o kc.o && '"$kc_link" >"$work/build8.log" 2>"$work/build8.err"
rc=$?
[ "$rc" = 0 ] && ok "a build against linux-headers succeeds" || { bad "a build against linux-headers succeeds (rc=$rc)"; tail -20 "$work/build8.err"; }
b8=$(sed -n 's/^bundle=//p' "$work/build8.log")
[ -f "$b8/payload/share/licenses/kc/linux-headers/linux/perm.h" ] &&
	ok "a used permissive-only kernel header carries its notice" || bad "a used permissive-only kernel header carries its notice"
[ ! -e "$b8/payload/share/licenses/kc/linux-headers/linux/note.h" ] &&
	ok "a header under the syscall note carries none" || bad "a header under the syscall note carries none"
! ls "$b8/payload/share/licenses/kc/" 2>/dev/null | grep -q '^linux-headers-' &&
	ok "the kernel's licences do not ship with a binary that only includes its headers" ||
	bad "the kernel's licences do not ship with a binary that only includes its headers"
! grep -q '^ *bundled' "$b8/MANIFEST" 2>/dev/null && ok "headers are not bundled" || bad "headers are not bundled"
run_kc w8b '$SOND_CC $SOND_CFLAGS -c kc.c -o kc.o && '"$kc_link" >/dev/null 2>"$work/build8b.err"
rc=$?
[ "$rc" != 0 ] && grep -q -- '-MD' "$work/build8b.err" &&
	ok "a build against linux-headers without dependency files is refused" ||
	bad "a build against linux-headers without dependency files is refused (rc=$rc: $(tail -2 "$work/build8b.err"))"

# A pure Go binary (licence opinion 2.10 (a)): no musl, the Go toolchain's licence and every
# linked module's licence files ship, module NOTICEs are aggregated, bundled lists go and each
# module, and a copyleft module puts the package in the source lane with that module's zip.
# Modules come from a file GOPROXY, so the test needs no network.
proxy=$work/goproxy
mkmod() { # <module> <licence text> [notice]
	python3 - "$proxy" "$1" "$2" "${3:-}" <<'PY'
import os, sys, zipfile
proxy, mod, licence, notice = sys.argv[1:]
d = os.path.join(proxy, mod, "@v")
os.makedirs(d, exist_ok=True)
pkg = mod.rsplit("/", 1)[-1]
gomod = "module %s\n\ngo 1.22\n" % mod
open(os.path.join(d, "list"), "w").write("v1.0.0\n")
open(os.path.join(d, "v1.0.0.info"), "w").write('{"Version":"v1.0.0"}\n')
open(os.path.join(d, "v1.0.0.mod"), "w").write(gomod)
with zipfile.ZipFile(os.path.join(d, "v1.0.0.zip"), "w") as z:
    root = "%s@v1.0.0/" % mod
    z.writestr(root + "go.mod", gomod)
    z.writestr(root + "LICENSE", licence)
    if notice:
        z.writestr(root + "NOTICE", notice)
    z.writestr(root + pkg + ".go", 'package %s\n\nfunc Word() string { return "%s" }\n' % (pkg, pkg))
PY
}
mkmod example.com/greet "Permission is hereby granted, free of charge, to any person obtaining a copy" "greet NOTICE: Copyright 2026 Greet Authors"
mkmod example.com/mozilla "Mozilla Public License Version 2.0"
gofork() { # <dir> <module to use>
	mkdir -p "$1"
	printf 'module example.com/hi\n\ngo 1.22\n\nrequire %s v1.0.0\n' "$2" >"$1/go.mod"
	printf 'package main\n\nimport (\n\t"fmt"\n\t"%s"\n)\n\nfunc main() { fmt.Println("hi-" + %s.Word()) }\n' "$2" "${2##*/}" >"$1/main.go"
	printf '                                 Apache License\n                           Version 2.0, January 2004\n' >"$1/COPYING"
	(cd "$1" && GOPROXY=file://$proxy GOSUMDB=off GOFLAGS=-mod=mod GOMODCACHE=$work/gomod-prep go mod tidy >/dev/null 2>&1)
	git -C "$1" init -q -b sond && gitc "$1" add -A && gitc "$1" commit -q -m hi
}
go_build='mkdir -p "$SOND_PAYLOAD/bin" && CGO_ENABLED=0 go build -trimpath -buildvcs=false -o "$SOND_PAYLOAD/bin/hi" .'
run_go() { # <workspace> <fork>
	GOPROXY=file://$proxy GOSUMDB=off GOFLAGS=-mod=mod GOMODCACHE=$work/$1/gomod GOTOOLCHAIN=local \
	SOND_WORK=$work/$1/sond RUNNER_TEMP=$work/$1 SOND_DISTRO_PKG=${SOND_DISTRO_PKG:-} \
		bash "$here/build.sh" --fork "$2" --repository fredyk/hi-sond --name hi --version 1.0 --license Apache-2.0 \
		--upstream "github.com/example/hi@$(git -C "$2" rev-parse HEAD)" --license-file COPYING \
		--linkage "static Go $(go env GOVERSION | sed 's/^go//'), no libc" --build "$go_build" --out "$work/out-$1"
}
gofork "$work/hi-sond" example.com/greet
mkdir -p "$work/w9/sond/forks" && cp -a "$work/w/forks/toolchain" "$work/w9/sond/forks/"
run_go w9 "$work/hi-sond" >"$work/build9.log" 2>"$work/build9.err"
rc=$?
[ "$rc" = 0 ] && ok "a pure Go build succeeds" || { bad "a pure Go build succeeds (rc=$rc)"; tail -20 "$work/build9.err"; }
b9=$(sed -n 's/^bundle=//p' "$work/build9.log")
l9=$b9/payload/share/licenses/hi
[ "$("$b9/payload/bin/hi" 2>/dev/null)" = "hi-greet" ] && ok "the Go binary runs" || bad "the Go binary runs"
grep -q "\"go $(go env GOVERSION | sed 's/^go//') BSD-3-Clause\"" "$b9/MANIFEST" 2>/dev/null &&
	ok "bundled lists the Go toolchain" || bad "bundled lists the Go toolchain"
grep -q '"example.com/greet v1.0.0 MIT"' "$b9/MANIFEST" 2>/dev/null &&
	ok "bundled lists each module with the licence its files name" || bad "bundled lists each module with the licence its files name"
[ -f "$l9/go-LICENSE" ] && ok "Go's licence ships" || bad "Go's licence ships"
[ -f "$l9/go/example.com/greet@v1.0.0/LICENSE" ] && ok "the module's licence ships" || bad "the module's licence ships"
grep -q 'greet NOTICE: Copyright 2026 Greet Authors' "$l9/NOTICE" 2>/dev/null &&
	ok "the module's NOTICE is in the aggregated NOTICE" || bad "the module's NOTICE is in the aggregated NOTICE"
[ -f "$l9/COPYING" ] && [ ! -e "$l9/musl-COPYRIGHT" ] && ok "Apache text ships and no musl COPYRIGHT" || bad "Apache text ships and no musl COPYRIGHT"
! grep -q '^source_bundle=' "$work/build9.log" && ok "a permissive Go package needs no source lane" || bad "a permissive Go package needs no source lane"
gofork "$work/hi-mpl-sond" example.com/mozilla
mkdir -p "$work/w9b/sond/forks" && cp -a "$work/w/forks/toolchain" "$work/w9b/sond/forks/"
run_go w9b "$work/hi-mpl-sond" >"$work/build9b.log" 2>"$work/build9b.err"
rc=$?
[ "$rc" = 0 ] && ok "a Go build linking an MPL module succeeds" || { bad "a Go build linking an MPL module succeeds (rc=$rc)"; tail -20 "$work/build9b.err"; }
s9=$(sed -n 's/^source_bundle=//p' "$work/build9b.log")
[ -n "$s9" ] && python3 -c 'import sys, zipfile; print("\n".join(zipfile.ZipFile(sys.argv[1]).namelist()))' "$s9/payload/share/src/hi/example.com/mozilla@v1.0.0.zip" 2>/dev/null | grep -q 'mozilla.go' &&
	ok "the MPL module's source is in the source bundle" || bad "the MPL module's source is in the source bundle ($(ls -R "$s9/payload/share/src" 2>&1 | head -5))"

[ "$fail" = 0 ] && printf 'test-build: OK\n' || printf 'test-build: FAIL\n'
exit $fail
