# Development

```console
tools/bootstrap       # one-off: fetch a Ruby if you have none
tools/test            # run the suite
tools/test openings   # run matching groups only
tools/syntax          # parse every Ruby file, SketchUp adapter included
tools/ruby FILE.rb    # run any script
tools/demo            # build the demo building headlessly
tools/build           # package dist/openwalls-<version>.rbz
```

With a native Ruby on `PATH`, `tools/test` and `tools/syntax` simply exec it,
and `rake` works too (`rake`, `rake test`, `rake build`, `rake preview`).

## Running without Ruby

This project was written in a sandbox with no Ruby interpreter and no way to
install one — no root, no package manager, no access to `cache.ruby-lang.org`.
`tools/ruby` exists for that situation: it runs the official CRuby 3.3
`ruby.wasm` build on Node's WASI.

```console
$ tools/bootstrap
  No ruby found. Fetching CRuby 3.3 compiled to WebAssembly (~36 MB)...
  ruby 3.3.3 on wasm32-wasi
  Ready. Try:  ./tools/test
```

The runner itself is `tools/wasm-ruby/rubyw.mjs`, checked in and about 200
lines; `tools/bootstrap` only downloads the interpreter next to it.

It is good enough to develop the whole geometry engine against, and it is why
the engine has no gem dependencies at all — not even for tests or CSV. The
test harness in `test/harness.rb` is about a hundred lines of plain Ruby. That
constraint turned out to be a feature: the suite also runs unmodified inside
SketchUp's own Ruby console, where there is no bundler either.

### ruby.wasm quirks, documented so nobody rediscovers them

* `$stdout.sync = true` corrupts the VM. Later `File.read` or
  `TOPLEVEL_BINDING` access segfaults. Flush explicitly instead.
* `load`, `require` via `$LOAD_PATH` and `require_relative` against the host
  filesystem all segfault. `tools/ruby` resolves `require_relative`
  **statically on the JS side**, inlining the whole dependency graph into one
  source string and evaluating it once.
* Calling `eval` once per file segfaults non-deterministically — roughly half
  the time at a dozen files. Hence the single-eval bundler above.
* The GC is unstable under Node's WASI and will segfault at random once a
  process has allocated enough. A small initial heap with a low malloc trigger
  survives far more often than the defaults; `tools/test` additionally runs
  one group per process and retries a crashed shard, falling back to one
  process per test. A shard that keeps crashing is reported separately from a
  failing test, so a crash can never be mistaken for a pass.
* `Dir.entries` and recursive `**` globs over the host filesystem segfault.
  Pass explicit paths.

None of this affects the extension. It is a development-environment story
only; in SketchUp the code runs on ordinary CRuby.

## Compatibility

The whole codebase is Ruby 2.7 syntax: no endless methods, no `Data.define`,
no hash shorthand. That is what lets OpenWalls support SketchUp 2021 rather
than 2024+. CI runs the suite on 2.7, 3.2 and 3.3.

## Adding a feature to the engine

1. Write the test first, as a closed-form assertion. If you cannot say what
   the volume should be, the feature is not specified yet.
2. Put the geometry in `src/openwalls/core/`. If you find yourself wanting
   `Sketchup.active_model` there, the design has gone wrong — `tools/build`
   will refuse to package it.
3. Expose it in the adapter and the panel last.
