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

[ "$fail" = 0 ] && printf 'test-build: OK\n' || printf 'test-build: FAIL\n'
exit $fail
