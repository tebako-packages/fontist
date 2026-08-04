# fontist feedstock — build notes

Everything a reviewer needs to reproduce or extend the `3.0.10` payloads:
what the dependency tree looks like, how the build is self-hosted, what
was proven, and what is deferred.

> **Era note (2026-08-05).** The legs now build with the **released
> tebako CLI v0.1.1** (pinned, sha256-pinned in the workflow) against the
> **image-era runtime line 0.16.2** — the 0.15.9-era flow described in
> §2–§6 below (from-source CLI build, feedstock-side SDK, `sdk_patch.rb`,
> 0.15.9 shim shape) is superseded: the CLI provisions the runtime SDK
> itself on POSIX, and the v0.1.1 resolver refuses pre-era runtimes by
> contract (exit 75). § Windows describes the second leg and the runtime
> blocker that gates its publication.

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
workflow is triggered on push. Early runs failed on workflow-file issues
(inline `permissions:` mapping; missing `dwarfs-rs` sibling clone;
missing vcpkg/submodule recipe) — each fixed as found, the CLI-build
step now mirrors tebako-rs's own `ci.yml` (recursive submodules, pinned
vcpkg). The full leg has not run green yet (the cold vcpkg build alone
is ~45 min) — treated as unproven until it does.

## 8. Windows leg (`x86_64-windows-ucrt`) — build green, publication gated at the runtime layer

### 8.1 Platform key

The payload platform axis is the spec 03 §3 vcpkg-triplet vocabulary
(`tpkg::Platform` in tamatebako/tebako is the single owner): the windows
leg is **`x86_64-windows-ucrt`** — the same GNU-style form as the existing
`aarch64-macos`. `windows-ucrt64` is the *release-asset-name* form of the
same platform and appears only in tool/runtime artifact names
(`tebako-0.1.1-windows-ucrt64.exe`,
`tebako-runtime-0.16.2-3.3.7-windows-ucrt64`). `universal` is NOT
available: §1 — the closure carries native extensions (nokogiri, ffi
precompiled per platform; brotli compiled per triplet), so the payload
ships per-triplet with the ABI-line `runtime_requirement ~> 3.3.0`.

### 8.2 The leg (mirrors the mac leg, one shell branch per divergence)

- **Packager**: `tebako`/`tfs` windows binaries from tamatebako/tebako
  **release v0.1.1**, sha256-pinned in the workflow (v0.1.1 predates the
  release's SHA256SUMS asset; digests recorded in §8.5). A stub
  `tebako press --tebako-version 0.16.2` resolves the runtime
  (`tebako-runtime-0.16.2-3.3.7-windows-ucrt64` + env `.tfs`,
  manifest-verified by the CLI's resolver) into `TEBAKO_HOME`.
- **Staging without a shim**: the deploy-driver ruby shim the mac leg
  stages through is **POSIX-only by construction** (tebako-cli
  `deploy.rs`: the shim is a `#!/bin/sh` re-entry script; a Windows shape
  is explicitly refused) and the memfs-exec spawn patch is POSIX-only
  too. The windows leg therefore runs its staging scripts as **entries of
  a purpose-built driver image**: `tfs mkimage` a dir with
  `stage_app.rb`/`stage_brotli_manual.rb`, then
  `rt.exe --tebako-image driver.tfs:-:/drv --tebako-entry /stage_app.rb`
  with `TEBAKO_RUNTIME_IMAGE=<env.tfs>` + `TEBAKO_PASS_THROUGH=1` (the
  spec 17 bare-image grammar; no tpkg trailer needed).
- **brotli** (the one source-only native): rubygems' ExtConfBuilder
  spawns `Gem.ruby` — impossible on Windows (no shim, no memfs spawn).
  `tools/stage_brotli_manual.rb` instead runs `extconf.rb` **in-process**
  (`$0` pinned to `extconf.rb` — mkmf anchors srcdir/TARGET on it), the
  host runs `make` (ucrt64 gcc), and the script installs the `.so` the
  way rubygems would (gem tree, `spec.to_ruby` stub, extensions
  bookkeeping with `Gem::Platform.local`, `gem.build_complete`).
  Validated on macOS arm64: the placed brotli loads and round-trips.
- **mkmf inputs**: headers from the recipe-pinned ruby 3.3.7 tarball
  (configure'd for x64-mingw-ucrt under MSYS2) and an **import library**
  generated from the built static libruby via `dlltool --export-all` —
  the runtime factory's own mechanism, so the extension imports
  `ruby.exp.dll`, the same module name the runtime's own extensions use.
- **Closure**: `closure/3.0.10-x86_64-windows-ucrt.txt` — the mac
  resolution with the two precompiled natives swapped for their
  `x64-mingw-ucrt` variants (`/info` checksums). Imaging: `tfs mkimage`
  (the release CLI's in-process Writer; no libtfs download on this leg).

### 8.3 The blocker: windows runtimes load no dynamic native extensions

The build above is green, but the boot smoke **cannot pass** against the
published windows runtimes. Evidence (runtime 0.16.2, 3.3.7):

1. `tebako-runtime-0.16.2-3.3.7-windows-ucrt64` is a static ruby
   (`configure_args` in the image's rbconfig: `--disable-shared
   --with-static-linked-ext`). Its PE has **no export table** (0 exports)
   and imports only system DLLs — there is no symbol provider a native
   extension could bind to.
2. The release ships **no ruby DLL** — not as an asset, not inside the
   env image (`tfs find rt.tfs '*.dll'` → nothing). The image's own
   three dynamic extensions (`debug`, `racc/cparse`, `rbs_extension`)
   import **`ruby.exp.dll`** (the `dlltool` default from the factory's
   `gnumakefile_in_pass2_msys` patch) — a module that exists nowhere, so
   they cannot load either; all three are gems with pure-ruby fallbacks,
   which is why the gap is invisible in the factory boot smoke.
3. Precompiled windows gems are equally dead: `nokogiri-...-x64-mingw-ucrt`'s
   `.so` imports `x64-msvcrt-ruby330.dll` (the RubyInstaller ABI name) —
   also absent.
4. Confirmed the failure is payload-visible: with the native `.so`s made
   unloadable in the *macOS* payload (same gem set), even
   `fontist --version` dies —
   `Moxml::AdapterError: Failed to load nokogiri adapter ... LoadError:
   cannot load such file -- nokogiri/nokogiri` (`require "lutaml/model"`
   at fontist boot loads moxml's nokogiri adapter). The windows CI leg
   reproduces the same signature natively; `tools/smoke_verdict` pins it.

**Fix shape (runtime factory, not this feedstock):** give the windows
runtime a symbol provider — link the `ruby.exp` export object into the
interpreter exe (the pass-2 GNUmakefile already generates it via
`dlltool --output-exp`; it is just never linked) and ship a
`ruby.exp.dll`-named forwarding alias + import library for payload-time
builds, plus an `x64-msvcrt-ruby330.dll` alias if precompiled
RubyInstaller gems should load. Until then the windows leg stays
build-only: `tools/smoke_verdict` turns exactly the known LoadError
signature green, fails any other failure mode, and **no windows artifact
is published** (the publish job needs only the mac leg; the registry
gains the windows entry when the gate is enforced).

### 8.4 What a linux leg would take

Structurally trivial now: `closure/3.0.10-x86_64-linux-gnu.txt` (mac
resolution with `ffi`/`nokogiri` swapped for their `x86_64-linux-gnu`
variants; brotli source-built like the mac leg — the shim flow works
unchanged on POSIX), one workflow job on `ubuntu-24.04` with the
`linux-gnu-x86_64` v0.1.1 tools, `TRIPLET=x86_64-linux-gnu`. The
`tools/build` case statement grows one arm (same staging family as mac;
imaging via `tfs mkimage` or the libtfs mkdwarfs linux asset).

### 8.5 Tool provenance (this era)

| tool | source | sha256 |
|------|--------|--------|
| `tebako-0.1.1-windows-ucrt64.exe` | tamatebako/tebako v0.1.1 | `9cd4f2e0922acb776797a284f2f3ea1448f93c228c92e84b0f1f7a322857c2b8` |
| `tfs-0.1.1-windows-ucrt64.exe` | tamatebako/tebako v0.1.1 | `82ed22135321449c81530e1fabeba73555195ea411e0d9cca4458a23fe5ad01c` |
| `tebako-0.1.1-macos-arm64` | tamatebako/tebako v0.1.1 | `025fdf6948ab678895004349c7ada9c4a13676de5d1eb71bdac40dedcae73d84` |
| `tfs-0.1.1-macos-arm64` | tamatebako/tebako v0.1.1 | `b1848bda4d12ec520faa682adf293f58e07ba6fedc28e373911cff24e56fe412` |
| runtime (both legs) | tebako-runtime-ruby v0.16.2, ruby 3.3.7 | release manifest (CLI-verified) |
| `mkdwarfs-macos-arm64` (mac imaging) | tamatebako/libtfs v0.13.0 | release SHA256SUMS |
| ruby SDK tarball (windows brotli) | cache.ruby-lang.org | `9c37c3b1…8628` (recipe pin) |
