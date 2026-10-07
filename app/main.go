// Command app renders a fixed scene for a fixed number of frames and reports
// heap allocations per frame, measured after a warm-up period.
// Build it with go.mod (official ebiten + purego) or -modfile=patched.mod.
package main

import (
	"crypto/sha256"
	"flag"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"math"
	"os"
	"runtime"
	"runtime/pprof"

	"github.com/hajimehoshi/ebiten/v2"
)

var (
	warmup     = flag.Int("warmup", 300, "frames to skip before measuring")
	frames     = flag.Int("frames", 3000, "frames to measure")
	sprites    = flag.Int("sprites", 500, "DrawImage calls per frame")
	vsync      = flag.Bool("vsync", false, "enable vsync (presents every frame, like a real game)")
	label      = flag.String("label", "app", "name printed in the report")
	pngOut     = flag.String("png", "", "save the hashed frame as a PNG to this file")
	memprofile = flag.String("memprofile", "", "write a heap profile of the measured frames to this file")
)

type game struct {
	sprite *ebiten.Image
	op     ebiten.DrawImageOptions
	frame  int
	before runtime.MemStats
}

func (g *game) Update() error {
	g.frame++
	switch g.frame {
	case *warmup:
		if *memprofile != "" {
			runtime.MemProfileRate = 1 // record every allocation from here on
		}
		runtime.GC()
		runtime.ReadMemStats(&g.before)
	case *warmup + *frames:
		var after runtime.MemStats
		runtime.ReadMemStats(&after)
		report(&g.before, &after)
		return ebiten.Termination
	}
	return nil
}

func (g *game) Draw(screen *ebiten.Image) {
	screen.Fill(color.RGBA{0x20, 0x20, 0x30, 0xff})
	w, h := screen.Bounds().Dx(), screen.Bounds().Dy()
	t := float64(g.frame) / 60
	for i := range *sprites {
		a := t + float64(i)*0.37
		g.op.GeoM.Reset()
		g.op.GeoM.Translate(float64(w)/2+math.Cos(a)*float64(w)/3, float64(h)/2+math.Sin(a*1.3)*float64(h)/3)
		screen.DrawImage(g.sprite, &g.op)
	}
	// Hash one frame before measuring, to show both builds render the same pixels.
	if g.frame == *warmup-1 {
		pixels := make([]byte, 4*w*h)
		screen.ReadPixels(pixels)
		fmt.Printf("%-9s frame %d %dx%d sha256=%x\n", *label, g.frame, w, h, sha256.Sum256(pixels))
		if *pngOut != "" {
			f, err := os.Create(*pngOut)
			if err != nil {
				panic(err)
			}
			defer f.Close()
			if err := png.Encode(f, &image.RGBA{Pix: pixels, Stride: 4 * w, Rect: image.Rect(0, 0, w, h)}); err != nil {
				panic(err)
			}
		}
	}
}

func (g *game) Layout(w, h int) (int, int) { return w, h }

func report(b, a *runtime.MemStats) {
	n := float64(*frames)
	fmt.Printf("%-9s frames=%d  allocs=%d  allocs/frame=%8.2f  bytes/frame=%9.1f  GCs=%d  GC pause total=%.2fms\n",
		*label, *frames, a.Mallocs-b.Mallocs,
		float64(a.Mallocs-b.Mallocs)/n,
		float64(a.TotalAlloc-b.TotalAlloc)/n,
		a.NumGC-b.NumGC,
		float64(a.PauseTotalNs-b.PauseTotalNs)/1e6)
	if *memprofile == "" {
		return
	}
	f, err := os.Create(*memprofile)
	if err != nil {
		panic(err)
	}
	defer f.Close()
	runtime.GC() // the heap profile only includes allocations up to the last completed GC
	if err := pprof.Lookup("allocs").WriteTo(f, 0); err != nil {
		panic(err)
	}
}

func main() {
	flag.Parse()
	sprite := ebiten.NewImage(16, 16)
	sprite.Fill(color.RGBA{0xff, 0xa0, 0x40, 0xff})

	ebiten.SetWindowTitle(*label)
	ebiten.SetWindowSize(640, 480)
	ebiten.SetVsyncEnabled(*vsync)
	ebiten.SetTPS(ebiten.SyncWithFPS) // one Update per Draw, so "per frame" is exact
	if err := ebiten.RunGame(&game{sprite: sprite}); err != nil {
		panic(err)
	}
}
