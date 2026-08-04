# tebako-packages/fontist

Feedstock for **fontist** — the first `kind: app` payload of the
`tebako-packages` org (a runtime-required ruby application, as opposed to
self-contained `kind: toolkit` payloads).

- Upstream: [fontist](https://github.com/fontist/fontist) 3.0.10 (RubyGems)
- Payload: `fontist-3.0.10-aarch64-macos.tfs` (DwarFS image, per-triplet);
  an `x86_64-windows-ucrt` leg builds in CI but does not publish yet
  (the windows runtimes load no dynamic native extensions —
  `docs/build-notes.md` § Windows)
- Registry: `tfs:github:tebako-packages/fontist` (see `tpkg-registry.yaml`)

## Layout

- `recipe.yml` — upstream, runtime, resolution pins, platforms, entrypoints
- `manifests/payload.yaml` — the spec 03 payload manifest (filled at build)
- `tpkg-registry.yaml` — this feedstock's registry (pinned at release)
- `tools/` — `build` (stage → image → manifest), `boot_smoke`, `publish`
- `docs/build-notes.md` — dep-tree findings, what ran, what's deferred

## Why triplet-bound

fontist's closure contains native extensions (nokogiri, ffi — precompiled
per platform; brotli — compiled per triplet during the build), so the
payload ships per-triplet and its runtime requirement is the ABI line
`~> 3.3.0`, not a pure-ruby range. Details: `docs/build-notes.md`.

## Using

```console
$ tebako add-registry tfs:github:tebako-packages/fontist   # dispatcher: roadmap
$ tebako install fontist@3.0.10                            # installs the payload record
$ fontist --version                                        # via the shim layer
```

Today (pre-dispatcher), the verified exec is documented in
`docs/build-notes.md` § Verification.
