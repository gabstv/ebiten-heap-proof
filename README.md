# Ebitengine heap allocation proof

[![proof](https://github.com/gabstv/ebiten-heap-proof/actions/workflows/proof.yml/badge.svg)](https://github.com/gabstv/ebiten-heap-proof/actions/workflows/proof.yml)

This repo shows that Ebitengine can draw frames with **no heap allocations per frame** on macOS, Linux
and Windows, with a few changes to Ebitengine and purego. Today it allocates about 480 times per frame
on macOS, 35 on Linux and 14 on Windows.

Every push runs the proof on GitHub Actions: on an Apple Silicon Mac (`macos-latest`, which also runs
the Intel builds with Rosetta 2), an Intel Mac (`macos-15-intel`), Linux (`ubuntu-latest`) and Windows
(`windows-latest`). Open the [latest run](https://github.com/gabstv/ebiten-heap-proof/actions/workflows/proof.yml)
to see the results tables and download the full reports and heap profiles.

It builds the same small app twice:

| build      | module file       | Ebitengine                            | purego                               |
|------------|-------------------|---------------------------------------|--------------------------------------|
| `official` | `app/go.mod`      | upstream `main` at `9e6aa156c`        | v0.11.1                              |
| `patched`  | `app/patched.mod` | same commit + changes ([branch][eb])  | `main` + changes ([branch][pg])      |

The app code is the same for both. Only the dependencies differ.

[eb]: https://github.com/gabstv/ebiten/tree/zero-alloc
[pg]: https://github.com/gabstv/purego/tree/zero-alloc

## Running it

You need Go 1.26 or newer, and a desktop: macOS, Linux with X11, or Windows (in Git Bash).
On an Apple Silicon Mac, the Intel builds also run if Rosetta 2 is installed
(`softwareupdate --install-rosetta`).

```sh
./run.sh
./check.sh
```

A window opens and closes a few times. `run.sh` saves its output to `app/out/report.txt`, and
`check.sh` checks it and prints the results as a table. On Linux and Windows, tell `check.sh` which
graphics library to expect: `EXPECTED_GRAPHICS=OpenGL ./check.sh` or `EXPECTED_GRAPHICS=DirectX ./check.sh`.

The app draws 500 sprites per frame. It skips the first 300 frames (warm-up), then counts heap
allocations with `runtime.ReadMemStats` over the next 3000 frames (1200 with vsync on). In the middle
of the warm-up it prints a SHA-256 of one rendered frame, so you can check that both builds draw the
same image.

`check.sh` fails if:

- a build did not use the expected graphics library (Metal, OpenGL or DirectX),
- two builds drew a different image for the same frame,
- a patched build allocated once per frame or more,
- in the steady-state step, a patched run of 12,000 frames made 0.05 or more allocations per frame
  more than a run of 3,000 frames, so anything that allocates every 20 frames fails,
- or an official build did not allocate, which would mean the measurement is broken.

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

From a GitHub Actions run. "Per frame" is the allocations in the whole measured run divided by the
number of frames.

| platform | graphics | official, per frame | patched, per frame | patched, whole run | GCs, official / patched |
|----------|----------|--------------------:|-------------------:|-------------------:|------------------------:|
| macOS, Apple Silicon | Metal   | ~465–493 | 0.02–0.06 | 47–166  | 15–16 / 0 |
| macOS, Intel         | Metal   | ~589–595 | 0.04–0.07 | 133–223 | 19 / 0 |
| Linux                | OpenGL  | ~35      | 0.03–0.04 | 101–110 | 1 / 0 |
| Windows              | DirectX | ~14      | 0.04–0.05 | 126–163 | 0 / 0 |

With vsync on, the official builds allocate about 683–687 times per frame on macOS, 35 on Linux and 14
on Windows, and the patched builds 0.06–0.09.

All builds draw the same frames on every platform.

### What "no allocations per frame" means here

No code that runs for each frame allocates anymore. The patched builds still allocate a little, but
not for each frame:

- **At the start**, for example while `sync.Pool`s and buffers fill up. This is most of the
  "whole run" numbers above.
- **A slow trickle** of about 0.01–0.03 allocations per frame, which the steady-state step measures. It
  comes from the Go runtime and `sync.Pool` refilling their per-thread caches when Ebitengine's
  goroutines move between OS threads, and from buffers sometimes growing to a new largest size. It is
  about 2 bytes per frame. With Ebitengine's single-thread mode (`-singlethread`), it drops by more than
  half.

Go also forces a GC every 2 minutes, even when nothing allocates. That is the one GC in a few of the
longer runs.

## Where the allocations came from

**macOS.** Most allocations came from `objc.Send` / `ID.Send` in purego, which use reflection on every
call, and from Go functions that Objective-C calls (input events, the display link), which purego also
calls through reflection.

**Linux.** X11 and GLX functions that run every frame or regularly (`XQueryPointer`, `XPending`,
`glXSwapBuffers`, `XGetWindowAttributes`, ...) were called through `purego.RegisterLibFunc`, which uses
reflection, and their result variables moved to the heap.

**Windows.** Win32 functions that run every frame (`GetKeyState`, `GetCursorPos`, `PeekMessageW`, ...)
were called through `LazyProc.Call`, which allocates its argument slice and moves the variables whose
addresses are passed to the heap.

## The changes

**purego**
- Fixed-arity `Syscall0`–`Syscall15`. The variadic `SyscallN` allocates its argument slice on
  every call from another module. This is
  [ebitengine/purego#445](https://github.com/ebitengine/purego/pull/445) with the changes asked for
  in its review.
- `SyscallMixed` and `SyscallMixedStret`, to pass struct and float arguments and return structs
  without reflection.
- `CallbackAdapter`: when C or Objective-C calls a Go function (callbacks, methods, blocks), purego can
  call it directly instead of through reflection. `objc.NewIMP` and `objc.NewBlock` use it for common
  signatures.

purego's own CI passes on these changes on macOS, Linux, Windows, Android, FreeBSD and NetBSD.

**Ebitengine**
- macOS: calls `objc_msgSend` through the functions above instead of `objc.Send`. Structs follow each
  CPU's calling convention: for example, an `NSRect` goes in float registers on Apple Silicon, and on
  the stack on Intel.
- Linux: calls the X11 and GLX functions above through the fixed-arity `Syscall` functions, and writes
  their results to fields of long-lived objects instead of local variables.
- Windows: calls Win32 functions through `syscall.SyscallN`, which is what `LazyProc.Call` does without
  the allocations.
- All platforms: removes a few more per-frame allocations (reused buffers in the Metal driver, no
  interface conversions of Metal objects, and so on).

Some calls still allocate, such as texture uploads and one-time setup. They don't run every frame.

## Checks

- Ebitengine's `go test -run TestImage .` passes with the patched Ebitengine on Apple Silicon and Intel
  Macs (Rosetta 2).
- The purego tests pass on all its CI platforms, including new tests that check the fixed-arity
  functions with each number of arguments and that the new functions and adapted callbacks do not
  allocate.
- `go vet` reports the same warnings as upstream on macOS, Linux and Windows.
