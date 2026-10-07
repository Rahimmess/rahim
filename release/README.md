# Download

**[openwalls-0.1.0.rbz](openwalls-0.1.0.rbz)** — 57 kB

Install in SketchUp: **Extensions → Extension Manager → Install Extension**,
then pick the downloaded file.

Requires SketchUp 2021 or newer, Windows or macOS. SketchUp Free, Go and the
web version cannot run extensions of any kind.

This archive is built by [`tools/build`](../tools/build) from
[`src/`](../src), which also refuses to package a release whose geometry core
references the SketchUp API. To rebuild it yourself:

```console
$ tools/build
  dist/openwalls-0.1.0.rbz  (37 files, 57.4 kB)
```

Verify what you are installing — it is a zip:

```console
$ unzip -l release/openwalls-0.1.0.rbz
```
