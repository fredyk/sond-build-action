#!/bin/bash
# action.yml wraps build.sh as a composite action: every build.sh option has an
# input, inputs reach the shell only through env (never ${{ inputs.* }} inside
# run:), the musl prefix is cached by the pinned musl commit, and the outputs
# come from build.sh's bundle= and payload_hash= lines.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
exec python3 - "$here/action.yml" <<'PY'
import re, sys, yaml
fail = 0
def check(cond, what):
    global fail
    print(("ok   " if cond else "FAIL ") + what)
    fail |= not cond
try:
    a = yaml.safe_load(open(sys.argv[1]))
except Exception as e:
    print(f"FAIL action.yml parses ({e})"); print("test-action: FAIL"); sys.exit(1)
inputs = a.get("inputs") or {}
steps = (a.get("runs") or {}).get("steps") or []
check((a.get("runs") or {}).get("using") == "composite", "a composite action")
for i in ["name", "version", "license", "upstream", "build", "license-files", "linkage", "tier", "fork-path", "out", "distro-pkg-ref"]:
    check(i in inputs, f"input {i}")
for i in ["name", "version", "license", "upstream", "build"]:
    check(inputs.get(i, {}).get("required") is True, f"input {i} is required")
runs = [s.get("run", "") for s in steps]
check(not any("${{" in r for r in runs), "no ${{ }} expression inside any run: (inputs go through env)")
build = next((s for s in steps if s.get("id") == "build"), {})
check('"$GITHUB_ACTION_PATH/build.sh"' in build.get("run", ""), "the build step runs build.sh from the action")
check(re.search(r'>>\s*"\$GITHUB_OUTPUT"', build.get("run", "")) is not None, "build.sh's stdout becomes the step outputs")
outs = a.get("outputs") or {}
for o in ["bundle", "payload_hash"]:
    check(outs.get(o, {}).get("value") == "${{ steps.build.outputs.%s }}" % o, f"output {o} from the build step")
cache = next((s for s in steps if str(s.get("uses", "")).startswith("actions/cache@")), {})
w = cache.get("with") or {}
check(str(w.get("path", "")).endswith("/sond/forks/toolchain"), "the musl prefix is cached")
check("steps.distro.outputs.musl_commit" in str(w.get("key", "")), "the cache key names the pinned musl commit")
check("steps.distro.outputs.recipe" in str(w.get("key", "")), "the cache key names the toolchain recipe")
idx = {id(s): n for n, s in enumerate(steps)}
check(cache and build and idx[id(cache)] < idx[id(build)], "the cache is restored before the build")
up = next((s for s in steps if str(s.get("uses", "")).startswith("actions/upload-artifact@")), {})
check("steps.build.outputs.bundle" in str((up.get("with") or {}).get("path", "")), "the bundle is uploaded as an artifact")
print("test-action: " + ("FAIL" if fail else "OK"))
sys.exit(fail)
PY
