// NotallyXYZ for Linux and Windows: NotallyX notes with end-to-end encrypted sync.
package main

import (
	"embed"
	"log"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
	"github.com/wailsapp/wails/v2/pkg/options/linux"
	"github.com/wailsapp/wails/v2/pkg/options/windows"
)

//go:embed all:frontend/dist
var assets embed.FS

//go:embed build/appicon.png
var icon []byte

// version is set at build time: -ldflags "-X main.version=1.1.0".
var version = "dev"

func main() {
	app := NewApp()
	err := wails.Run(&options.App{
		Title:     "NotallyXYZ",
		Width:     1120,
		Height:    760,
		MinWidth:  640,
		MinHeight: 480,
		AssetServer: &assetserver.Options{
			Assets:  assets,
			Handler: app.attachmentHandler(),
		},
		BackgroundColour:         &options.RGBA{R: 0xF4, G: 0xF5, B: 0xF8, A: 0xFF},
		EnableDefaultContextMenu: true, // copy and paste in text fields
		OnStartup:                app.startup,
		OnBeforeClose:            app.beforeClose,
		OnShutdown:               app.shutdown,
		Bind:                     []any{app},
		SingleInstanceLock: &options.SingleInstanceLock{
			UniqueId:               "com.notallyxyz.desktop",
			OnSecondInstanceLaunch: app.secondInstance,
		},
		Windows: &windows.Options{Theme: windows.SystemDefault},
		Linux:   &linux.Options{Icon: icon, ProgramName: "notallyxyz"},
	})
	if err != nil {
		log.Fatal(err)
	}
}
