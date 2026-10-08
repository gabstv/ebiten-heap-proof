module heapproof

go 1.27.0

require github.com/hajimehoshi/ebiten/v2 v2.11.0-alpha.0.20261008100745-9e6aa156c5f9

require (
	github.com/ebitengine/gomobile v0.0.0-20260820040257-d11f821a26a6 // indirect
	github.com/ebitengine/hideconsole v1.0.0 // indirect
	github.com/ebitengine/purego v0.11.1 // indirect
	golang.org/x/sync v0.23.0 // indirect
	golang.org/x/sys v0.48.0 // indirect
)

replace github.com/ebitengine/purego => github.com/gabstv/purego v0.12.0-alpha.1.0.20261008210505-bf824b7fa269

replace github.com/hajimehoshi/ebiten/v2 => github.com/gabstv/ebiten/v2 v2.0.0-20261008225932-d448a46a3666
