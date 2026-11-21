# sond-build-action

Builds a Sond package from a fork checkout: the fork's own build command
compiles a static binary against a pinned musl, and the action packs the result
into a verified RFC-0018 bundle (payload, manifest, licences, source tarball and
the fork commit it came from).

The packager (`sondpkg`) and the musl recipe come from
[fredyk/sond-distro-pkg](https://github.com/fredyk/sond-distro-pkg). musl is
built once per musl commit and cached.

## Usage

```yaml
jobs:
  package:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - id: sond
        uses: fredyk/sond-build-action@v1
        with:
          name: toybox
          version: 0.8.11
          license: 0BSD
          upstream: github.com/landley/toybox@<sha40>
          license-files: LICENSE
          build: |
            make defconfig
            make CC="$SOND_CC" CFLAGS="$SOND_CFLAGS" LDFLAGS="$SOND_LDFLAGS -static" toybox
            install -D toybox "$SOND_PAYLOAD/bin/toybox"
      - run: echo "${{ steps.sond.outputs.payload_hash }}"
```

## Inputs

| input | required | default | meaning |
|---|---|---|---|
| `name` | yes | | package name |
| `version` | yes | | package version |
| `license` | yes | | SPDX expression |
| `upstream` | yes | | `HOST/OWNER/REPO@SHA40` the fork comes from |
| `build` | yes | | shell command run in the fork; installs into `$SOND_PAYLOAD` |
| `license-files` | | | one `PATH[=DEST]` per line, relative to the fork |
| `linkage` | | `static musl 1.2.5 (MIT)` | linkage line in the manifest |
| `tier` | | `public` | distribution tier |
| `fork-path` | | `.` | fork checkout (full clone) |
| `out` | | `sond-out` | where the bundle is written |
| `distro-pkg-ref` | | `main` | branch or tag of sond-distro-pkg |
| `upload-artifact` | | `true` | upload the bundle as an artifact |

The build command sees `SOND_CC`, `SOND_CFLAGS`, `SOND_LDFLAGS`,
`SOND_PAYLOAD` and `SOURCE_DATE_EPOCH`. musl's COPYRIGHT is added to every
package.

## Outputs

- `bundle`: path of the verified bundle.
- `payload_hash`: the bundle hash (sha256) from its manifest.

## Tests

```sh
tests/test-build.sh    # builds a toy fork end to end (needs gcc, make, git, python3)
tests/test-action.sh   # checks action.yml (needs python3-yaml)
```
