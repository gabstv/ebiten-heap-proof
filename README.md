# Ebitengine heap allocation proof (macOS)

[![proof](https://github.com/gabstv/ebiten-heap-proof/actions/workflows/proof.yml/badge.svg)](https://github.com/gabstv/ebiten-heap-proof/actions/workflows/proof.yml)

Every push runs the proof on GitHub Actions, on an Apple Silicon Mac (`macos-latest`, which also runs
the Intel builds with Rosetta 2) and on an Intel Mac (`macos-15-intel`). Both use Metal. Open the
[latest run](https://github.com/gabstv/ebiten-heap-proof/actions/workflows/proof.yml) to see the
results table and download the full report.

This repo shows that Ebitengine on macOS can run with **zero heap allocations per frame**,
instead of about 480 per frame today, with a few changes to Ebitengine and purego.

It builds the same small app twice:

| build      | module file       | Ebitengine                            | purego                               |
|------------|-------------------|---------------------------------------|--------------------------------------|
| `official` | `app/go.mod`      | upstream `main` at `9e6aa156c`        | v0.11.1                              |
| `patched`  | `app/patched.mod` | same commit + changes ([branch][eb])  | `main` + changes ([branch][pg])      |

The app code is the same for both. Only the dependencies differ.

[eb]: https://github.com/gabstv/ebiten/tree/zero-alloc
[pg]: https://github.com/gabstv/purego/tree/zero-alloc

## Running it

You need macOS and Go 1.26 or newer. To also run the Intel (amd64) builds on an Apple Silicon Mac,
you need Rosetta 2 (`softwareupdate --install-rosetta`).

```sh
./run.sh
```

A window opens and closes a few times. The output is also saved to `app/out/report.txt`.

Then check the report:

```sh
./check.sh
```

It fails if a build did not use Metal, if two builds drew a different image for the same frame,
or if a patched build allocated per frame. It also prints the results as a table.

The app draws 500 sprites per frame. It skips the first 300 frames (warm-up), then counts
heap allocations with `runtime.ReadMemStats` over the next 3000 frames (1200 with vsync on).
It also prints a SHA-256 of one rendered frame, so you can check that both builds draw the same image.

You can also run the app by hand:

```sh
cd app
go run . -label official
go run -modfile=patched.mod . -label patched
go run -modfile=patched.mod . -vsync -frames 1200
go run -modfile=patched.mod . -frames 1000 -memprofile patched.pprof
go tool pprof -sample_index=alloc_objects -top patched.pprof
```

## Results

Apple Silicon Mac, Go 1.27.0. The Intel numbers were measured with Rosetta 2 on the same Mac.

| build                  | allocations in the whole run | per frame | GCs |
|------------------------|-----------------------------:|----------:|----:|
| official, Apple Silicon        | ~1,450,000 | ~480 | 14–15 |
| patched, Apple Silicon         | 90–325     | 0    | 0     |
| official, Apple Silicon, vsync | ~823,000   | ~686 | 8     |
| patched, Apple Silicon, vsync  | ~200       | 0    | 0     |
| official, Intel                | ~1,430,000 | ~475 | 14    |
| patched, Intel                 | ~190       | 0    | 0     |
| official, Intel, vsync         | ~826,000   | ~689 | 8     |
| patched, Intel, vsync          | ~160       | 0    | 0     |

The patched builds still allocate a small fixed amount at the start, but it does not grow with
the number of frames: 10,000 and 30,000 frames both allocate about 270 objects. These are
one-time costs, like `sync.Pool` filling up. Go also forces a GC every 2 minutes, and refilling
the pools after it costs about 260 objects.

All builds render the same frame.

## Where the allocations came from

In the official build, a heap profile shows that most allocations come from `objc.Send` /
`ID.Send` in purego, which use reflection on every call. The rest came from small things in
Ebitengine's Metal and input code.

The changes:

**purego**
- Fixed-arity `Syscall0`–`Syscall15`. The variadic `SyscallN` allocates its argument slice on
  every call from another module. This is
  [ebitengine/purego#445](https://github.com/ebitengine/purego/pull/445) with the changes asked for
  in its review.
- `SyscallMixed` and `SyscallMixedStret`, to pass struct and float arguments and return structs
  without reflection.
- `CallbackAdapter`: when Objective-C calls a Go function (methods, blocks), purego can call it
  directly instead of through reflection. `objc.NewIMP` and `objc.NewBlock` use it for common signatures.

**Ebitengine**
- Calls `objc_msgSend` through the functions above instead of `objc.Send`. Structs follow each
  CPU's calling convention: for example, an `NSRect` goes in float registers on Apple Silicon,
  and on the stack on Intel.
- Removes per-frame allocations in the Metal driver and the input code (reused buffers,
  no interface conversions of Metal objects, and so on).

Some calls still use `objc.Send`, such as texture uploads and one-time setup. They don't run every frame.

## Checks

On both Apple Silicon and Intel (Rosetta 2):

- `go test -run TestImage .` in the patched Ebitengine passes.
- The purego tests pass, including new tests that check adapted callbacks do not allocate.
- `go vet` reports the same warnings as upstream.
