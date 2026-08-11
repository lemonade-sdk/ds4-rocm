# ds4-rocm

Prebuilt ROCm binaries for **[antirez/ds4](https://github.com/antirez/ds4)**
(DwarfStar 4), the inference engine for DeepSeek V4 Flash.

This repo exists for one reason: **ds4 publishes no binaries.** It has no
releases, no tags, and no build CI, so every user has to build it from source —
including installing rocWMMA headers that no Ubuntu package ships. That is a
hard blocker for using ds4 as a managed
[lemonade](https://github.com/lemonade-sdk/lemonade) backend, which expects to
download a versioned artifact like it does for every other engine.

This is the same role `lemonade-sdk/llamacpp-rocm` plays for llama.cpp's ROCm
builds, and the workflow here is modelled directly on it.

> **Status: experimental.** The ds4 ROCm backend itself is new, and this build
> pipeline is new. Treat releases as unstable.

## What a release contains

Each release is a tarball per GPU target with:

* the ds4 binaries — `ds4`, `ds4-server`, `ds4-bench`, `ds4-eval`, `ds4-agent`
  (~65 MB total; they are small)
* the ROCm runtime libraries they need, so the host does not need a system ROCm
  install: `libamdhip64`, `libhipblas`, `libhipblaslt`, `librocblas` and their
  dependencies, plus the hipBLASLt/rocBLAS tuning data

Run from the unpacked directory, or point `LD_LIBRARY_PATH` at it:

```sh
tar -xzf ds4-<sha>-linux-rocm-gfx1151-x64.tar.gz
cd ds4-<sha>-linux-rocm-gfx1151-x64
LD_LIBRARY_PATH=. ./ds4-server -m /path/to/model.gguf --port 8000
```

hipBLASLt and rocBLAS ship precompiled kernels for every GPU ROCm supports.
Since each archive targets one GPU, the build prunes the other architectures'
kernels — about **1.1 GiB** of dead weight per archive. The remaining bundle is
~485 MB unpacked, and was verified to run at full speed with the pruned data.

## Versioning

ds4 has no upstream versions to track, so a release is identified by **our own
monotonic build number** (`b0001`, `b0002`, …) and records exactly what went
into it:

```
Build Number:    b0001
GPU Target(s):   gfx1151
ROCm Version:    <therock version>
ds4 Commit Hash: <upstream sha>
Build Date:      <utc>
```

The upstream `ds4` **commit SHA** is the real identity; the build number is just
a stable, comparable handle for lemonade's `backend_versions.json` pin. This
mirrors how `lemonade-sdk/llamacpp-rocm` pins llama.cpp.

Because upstream is untagged and moves fast (37 commits in the week this repo
was created), a build number is the *only* durable way to say which ds4 a given
binary is.

## Scope

**Linux + `gfx1151` only, for now.** That is not laziness:

* ds4's ROCm backend is written for Strix Halo — `make rocm` is literally an
  alias for `make strix-halo`, and the default is `ROCM_ARCH ?= gfx1151`
* it depends on rocWMMA, so it needs RDNA3-class matrix instructions
* no other architecture is validated upstream

`ROCM_ARCH` is overridable, so other targets can be *built*. They have not been
*tested*, and this repo will not publish them until they are.

## Building

The workflow runs on a schedule and on demand. To cut a release manually, run
the **Build ds4 + ROCm** workflow with:

| input | default | meaning |
| --- | --- | --- |
| `ds4_ref` | `main` | upstream ref or SHA to build |
| `gfx_target` | `gfx1151` | comma-separated GPU targets |
| `rocm_version` | `latest` | TheRock ROCm dist version |
| `create_release` | `true` | publish a `b####` release |

To reproduce a build locally, see `scripts/build-ds4.sh`.

## License

The build tooling here is MIT. The ds4 binaries it packages are MIT, © the
ds4.c authors — see [antirez/ds4](https://github.com/antirez/ds4). ROCm runtime
libraries are redistributed under their own licenses.
