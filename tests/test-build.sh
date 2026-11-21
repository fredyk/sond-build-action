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

[ "$fail" = 0 ] && printf 'test-build: OK\n' || printf 'test-build: FAIL\n'
exit $fail
