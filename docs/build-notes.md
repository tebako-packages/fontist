# fontist feedstock — build notes

Everything a reviewer needs to reproduce or extend the `3.0.10` /
`aarch64-macos` payload: what the dependency tree looks like, how the
build is self-hosted, what was proven, and what is deferred.

## 1. Dependency-tree verdict: **triplet-bound**

`gem dependency fontist --remote` (v3.0.10):

```
down, excavate (>= 1.0.3), fontisan (>= 0.4.9), fuzzy_match, git, json,
lutaml-model (~> 0.8.0), marcel, nokogiri, octokit, paint, parallel,
plist, socksify, thor (~> 1.4), unibuf
```

The transitive closure (51 gems in the payload + 12 provided by the
runtime's default gems) contains **native extensions**:

| gem | native? | how the payload gets it |
|-----|---------|--------------------------|
| nokogiri 1.19.4 | C (vendored libxml2/libxslt) | **precompiled** `arm64-darwin` gem, sha256-verified against its `/info` checksum |
| ffi 1.17.4 | C | **precompiled** `arm64-darwin` gem, sha256-verified |
| brotli 0.8.0 | C (vendored brotli) | no precompiled gem exists → **built per triplet** against the SDK headers (§3) |
| json 2.7.2, bigdecimal 3.1.5, strscan 3.0.9, racc 1.7.3 | C | **runtime-provided** (default gems of the ruby 3.3.7 runtime; statically linked into its interpreter) |

So the payload is **not** `universal`: it ships per-triplet and the
entrypoint's `runtime_requirement` is the ABI line **`~> 3.3.0`** (the
staging/exec runtime is ruby 3.3.7), per spec 05 §5 ("native-extension
payloads lock to the ABI line"). The task's suggested
`>= 3.1, < 5.0` would be the honest constraint for a *pure-ruby* payload;
fontist is not one.

Everything else in the closure is pure ruby.

## 2. Self-hosting: no host ruby anywhere

Every ruby process in the build runs on the **published tebako runtime**
(`tebako-runtime-0.15.9-3.3.7-macos-arm64`, sha256-verified against the
tebako-runtime-ruby release manifest by tebako-cli's resolver):

- The runtime refuses to run scripts bare (`--tebako-image` is required
  and must carry a tpkg trailer). The build therefore drives it through
  the **deploy-driver shim** that tebako-cli's own `press` produces
  (`<prefix>/o/p/ruby` after a stub press) — the same mechanism the CLI
  uses for `bundle install`.
- Gem fetch is plain HTTPS (curl/python), never ruby: each `.gem` is
  downloaded from rubygems.org and sha256-verified against the compact
  index `/info/<gem>` checksum before staging. The pinned set is
  committed at `closure/3.0.10-aarch64-macos.txt`.
- The ruby tarball for the SDK headers is sha256-verified against the
  pin in `recipe.yml` (matches the ruby-lang.org release page).

## 3. Staging (what `tools/build` does)

1. Stub press → runtime resolved + deploy-driver shim.
2. SDK header dir: `ruby-3.3.7.tar.gz` (pinned, verified) → `configure`
   → `include/` + generated `ruby/config.h`. The runtime image ships no
   headers (`mkmf.rb can't find header files for ruby at
   /__tebako_memfs__/lib/ruby/include/ruby.h`), so `RUBYOPT` preloads
   `tools/sdk_patch.rb` for build processes: it points
   `rubyhdrdir/rubyarchhdrdir` at the SDK and replaces the static-libruby
   link (`-lruby.3.3-static`, present nowhere as a file) with
   `-Wl,-undefined,dynamic_lookup`, dropping the `-bundle_loader` flag
   (EXTDLDFLAGS) — the darwin idiom for extensions.
3. `gem install --local --ignore-dependencies` of the 51 pinned gems
   into the staging `GEM_HOME`. brotli builds its native extension here
   (host clang, runtime ruby driving mkmf — the RuntimeSdk-shaped
   approach). It is built `--enable-vendor` with
   `PKG_CONFIG_LIBDIR=/nonexistent`: by default the brotli gem links a
   **system** libbrotli (pkg-config finds Homebrew's), which a target
   machine may not have — the vendored build statically links brotli
   into the extension. Verified: `otool -L` on the payload's
   `brotli.bundle` lists only `libSystem`.
4. Assemble the payload root: `bin/fontist` (self-locating wrapper,
   `templates/`), `local/stub.rb` (v0.15.x launcher-ABI compat),
   `lib/ruby/gems/3.3.0/{gems,specifications,extensions,build_info}`.
   `.gem` caches and doc output are excluded.
5. `mkdwarfs-t` (pinned libtfs release asset) the tree →
   `fontist-3.0.10-aarch64-macos.tfs`.

### Resolution policy (pins and skips — each justified)

- **`liquid` pinned to 5.6.0.** liquid ≥ 5.6.1 requires `strscan >= 3.1.1`;
  strscan is a source-only native gem and the runtime's default is
  3.0.9. 5.6.0 requires `strscan >= 0` → satisfied by the runtime.
  fontist's constraint (`>= 4.0, < 6.0` via lutaml-xsd/lutaml-model) is
  honored.
- **Default-gem skips.** Constraints satisfied by the ruby 3.3.7 runtime's
  own default gems are not duplicated into the payload: `json` (~> 2.0),
  `bigdecimal`, `strscan`, `racc` (~> 1.4), `drb`, `uri` (>= 0.13.1),
  `logger` (>= 1.4.2), `minitest` (>= 5.1), `securerandom`, `benchmark`,
  `ostruct`, `rexml` (~> 3.3). This is the `kind: app` /
  runtime-required model working as designed — and it is why the abi-line
  constraint matters (the defaults are part of the runtime's ABI).
- **`gem install --conservative` does not work** for this: rubygems
  ignores statically-linked default specs ("extensions are not built")
  when resolving, and re-fetches the newest versions (incl. source-only
  natives). Hence the explicit pinned closure.

## 4. The `tebako press` Gemfile flow — findings (diagnosed 2026-07-27)

Pressing `Gemfile { source "https://rubygems.org"; gem "fontist" }` with
tebako-cli 0.15.9 **succeeds mechanically but resolves fontist 0.1.0**:

- tebako-cli runs `bundle install --prefer-local` (packager.rs, port of
  the gem). With `--prefer-local`, bundler 2.5 resolves through the
  legacy **dependency API** (`/api/v1/dependencies?gems=…`) instead of
  the compact index. That API is retired upstream (`404 The dependency
  API has gone away`, see the rubygems.org blog). Bundler degrades to
  versions whose dependency data needs no fetch — for fontist that is
  exactly `0.1.0` (zero runtime deps). Reproduced three ways; a plain
  `bundle lock` (no flag) on the same runtime resolves the full, correct
  3.0.10 tree.
- Even with a correct lockfile, the press cannot install the closure:
  the CLI pins `force_ruby_platform=true` (bundle config, env-scrubbed
  so it cannot be overridden), nokogiri then builds from source, and
  mkmf has no ruby headers in the runtime image (the RuntimeSdk
  subsystem is explicitly out of tebako-cli's current milestone).
- The press-machinery proof itself **passes**: the pressed package
  (`-m lean`) boots, resolves the runtime, mounts its image and runs the
  entry — transcript below.

These are noted for the tebako-cli tracker; the feedstock does not depend
on the press bundler path at all (it stages with `gem install`).

## 5. Verification (2026-07-27, macOS arm64)

- **Press proof** — `tebako press` of the Gemfile app, then the
  self-contained package runs network-free:

  ```
  $ ./fontist-app
  fontist (pressed Gemfile app): 0.1.0
  ```

- **Registry payload exec (dispatcher-equivalent)** — runtime ruby +
  payload tree + manifest entrypoint:

  ```
  $ <runtime> --tebako-image <driver>:0:/__tebako_memfs__ --tebako-entry ruby run.rb   # loads payload/bin/fontist
  fontist: 3.0.10
  formulas: { repo: https://github.com/fontist/formulas.git, version: v5, ... }
  $ fontist list | head -3        # network-free
  adobe_reader_19
   Adobe Arabic
    Bold (not installed)
  ```

  `list` exercises nokogiri (formula XML parsing) — the native stack
  loads and runs.
- **Image integrity** — `tfs ls/stat/cat` (in-process libtfs mount):
  `/bin/fontist` and `/local/stub.rb` present, 8373 entries;
  `dwarfsck` reads the metadata; `dwarfsextract` round-trip is
  byte-identical to the staged tree.
- **Dispatcher resolution** — `tebako-shim which fontist` against an
  installed payload record (`~/.tebako/payloads/fontist/3.0.10.tfs` +
  `.sha256` + manifest mirror) resolves the full chain and prints the
  spec-07 exec plan:

  ```
  runtime: ruby "~> 3.3.0" → ruby 3.3.7 (cached)
  mounts:  .../3.0.10.tfs:0:/
  exec:    <runtime> --tebako-image <payload.tfs>:0:/ --tebako-entry /bin/fontist
  ```

- **Known boundary (honest)**: the published v0.15.9 runtime (a)
  requires a tpkg trailer on `--tebako-image` (rejects bare registry
  `.tfs` payloads) and (b) mounts a single memfs — a runtime-required
  payload mounted at its memfs point shadows the ruby environment.
  The spec-07 bare-image, multi-mount dispatch is the image-era runtime
  ABI, not yet published for `macos-arm64` 3.3.7 (no `.tfs` asset and no
  manifest `image` key in the v0.15.9 release). Until then the payload
  carries `/local/stub.rb` (v0.15.x compat) and verification uses the
  dispatcher-equivalent exec above.

## 6. Tool provenance

| tool | source | pin |
|------|--------|-----|
| tebako-cli 0.15.9 | tamatebako/tebako-rs workspace build | `cargo build --release -p tebako-cli` |
| runtime | tebako-runtime-ruby v0.15.9, `tebako-runtime-0.15.9-3.3.7-macos-arm64` | sha256 `604e87a1…172b8` (release manifest, CLI-verified) |
| mkdwarfs-t (image build) | tamatebako/libtfs **v0.13.0** asset `mkdwarfs-macos-arm64` (v0.14.1) | sha256 `77c2d2c3…959c` (release SHA256SUMS-verified; `tebakofs-macos-arm64` `f29a5e19…9357` also fetched) |
| dwarfsck / dwarfsextract (aux checks) | tamatebako/dwarfs-t local build @ `1a43690` | **no GitHub releases exist for dwarfs-t**; the pinned distribution is the libtfs release above. (This local `dwarfsextract` is pathologically slow on the payload image — the round-trip check used tebako-rs `tfs extract`, 0.9 s.) |
| ruby SDK headers | cache.ruby-lang.org `ruby-3.3.7.tar.gz` | sha256 `9c37c3b1…8628` (ruby-lang.org) |

## 7. What ran vs what is deferred

Ran (this machine, transcripts above): staging, brotli native build,
payload image, all §5 verification, and the publish itself —

- Release: https://github.com/tebako-packages/fontist/releases/tag/3.0.10
- `fontist-3.0.10-aarch64-macos.tfs` — 11 726 637 bytes,
  sha256 `25dd5c74bc3581d361badf3b0be8fff72a5f110350ed9b48560b06d4704ea898`
  (re-downloaded from the release and re-hashed; `tpkg-registry.yaml`
  pinned to the same digest; `tebako-shim which fontist` resolves the
  release asset through an installed payload record)
- The committed `tools/build` reproduces the payload tree end-to-end
  (stub press → SDK → verified gems → stage → tree); the release image
  was built from that tree with the pinned libtfs mkdwarfs.

Deferred to CI (`.github/workflows/build-payload.yml`): the same build on
`macos-14`, boot-smoke gate, tag-triggered publish, and additional
triplets (`x86_64-macos` first; linux triplets need the same closure
re-resolved per triplet — brotli rebuild included). CI status: the
workflow is triggered on push; the first runs failed on a workflow-file
YAML issue (`permissions:` inline mapping — fixed in the repo after the
index template got the same fix), and the full leg has not run green
yet — treated as unproven until it does.
