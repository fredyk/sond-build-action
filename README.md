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
| `depends` | | | one `NAME VERSION` per line: published packages fetched from dist.sond.dev, checked under the pinned log key, into `$SOND_SYSROOT` (added to `SOND_CFLAGS`, `SOND_LDFLAGS` and pkg-config); their licences ship in the package |
| `linkage` | | `static musl 1.2.5 (MIT)` | linkage line in the manifest |
| `tier` | | `public` | distribution tier |
| `fork-path` | | `.` | fork checkout (full clone) |
| `out` | | `sond-out` | where the bundle is written |
| `distro-pkg-ref` | | `main` | branch or tag of sond-distro-pkg |
| `upload-artifact` | | `true` | upload the bundle as an artifact |

The build command sees `SOND_CC`, `SOND_CFLAGS`, `SOND_LDFLAGS`,
`SOND_PAYLOAD` and `SOURCE_DATE_EPOCH`. musl's COPYRIGHT is added to every
package.

## Linked components and the source lane

`SOND_CC` is a wrapper around the pinned `musl-gcc` that writes a linker map for every real link
(autoconf's `conftest` links are left out). A dependency whose archive the linker pulled in is
recorded in the manifest's `bundled` as `NAME VERSION LICENCE`, with musl next to it; one that is
only included is not.

The licence opinion (section 3) is applied before anything is built: when the licence is
copyleft or Apache-2.0, the `upstream` must be a commit (an annotated tag object is refused) and
every file the fork touches must carry `Modified by the Sond project, YYYY-MM-DD`; a GPL fork
may not carry Sond's Apache-2.0 header.

When the licence or a bundled component is copyleft (GPL, LGPL, MPL), the corresponding source
is built as `<name>-source`, linkage `source`, under `share/src/<name>/`: the fork at its
commit, the patches since upstream (`patches/`), `build-recipe.sh`, musl's source and the source
of every bundled component at the commit its own manifest names. The package names that bundle
in `source_object`, and dist.sond.dev refuses it until the source is logged: publish the
`source_bundle` output first (sond-publish-action's `source-bundle` input).

## Outputs

- `bundle`: path of the verified bundle.
- `payload_hash`: the bundle hash (sha256) from its manifest.
- `source_bundle`: path of the `<name>-source` bundle, set only in the source lane.

## Tests

```sh
tests/test-build.sh    # builds a toy fork end to end (needs gcc, make, git, python3)
tests/test-action.sh   # checks action.yml (needs python3-yaml)
```
