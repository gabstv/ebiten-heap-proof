#!/bin/bash
# Builds the same app against official and patched ebiten/purego, then compares heap allocations.
# The output is also saved to app/out/report.txt.
set -eo pipefail
cd "$(dirname "$0")/app"
mkdir -p bin out
exec > >(tee out/report.txt) 2>&1

exe=
case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*) exe=.exe ;;
esac
go build -o bin/official$exe .
go build -modfile=patched.mod -o bin/patched$exe .
# On macOS, also build for Intel. This needs an Intel Mac, or Rosetta 2 on Apple Silicon.
intel=false
if [ "$(uname -s)" = Darwin ] && arch -x86_64 /usr/bin/true 2>/dev/null; then
	intel=true
	GOARCH=amd64 go build -o bin/official-amd64$exe .
	GOARCH=amd64 go build -modfile=patched.mod -o bin/patched-amd64$exe .
fi

echo "== allocations per frame (3 runs each, 3000 measured frames, 500 sprites)"
for i in 1 2 3; do
	./bin/official$exe -label official
	./bin/patched$exe -label patched
done

echo
echo "== vsync on (presents every frame, like a real game; 1200 frames at the display rate)"
./bin/official$exe -label off-vsync -vsync -warmup 120 -frames 1200
./bin/patched$exe -label pat-vsync -vsync -warmup 120 -frames 1200

echo
if $intel; then
	echo "== Intel (amd64): must render the same frame hash"
	./bin/official-amd64$exe -label off-amd64
	./bin/patched-amd64$exe -label pat-amd64
	./bin/official-amd64$exe -label off-amd64-vsync -vsync -warmup 120 -frames 1200
	./bin/patched-amd64$exe -label pat-amd64-vsync -vsync -warmup 120 -frames 1200
elif [ "$(uname -s)" = Darwin ]; then
	echo "== Intel (amd64): skipped, Rosetta 2 is not installed"
fi

echo
echo "== heap profiles (1000 frames, every allocation recorded)"
./bin/official$exe -label official -frames 1000 -memprofile out/official.pprof >/dev/null
./bin/patched$exe -label patched -frames 1000 -memprofile out/patched.pprof >/dev/null
for v in official patched; do
	echo "-- $v: objects allocated under purego / objc / reflect"
	go tool pprof -sample_index=alloc_objects -top -focus='purego|reflect' bin/$v$exe out/$v.pprof 2>/dev/null | sed -n '/^Showing nodes/p' || true
	go tool pprof -sample_index=alloc_objects -top -nodecount=8 bin/$v$exe out/$v.pprof 2>/dev/null | sed -n '/flat%/,$p'
done
echo
echo "Inspect interactively: go tool pprof -http=: -sample_index=alloc_objects app/bin/official$exe app/out/official.pprof"
