// Command vectors prints the crypto test vectors used by all clients.
package main

import (
	"encoding/json"
	"os"

	"notallyxyz-server/internal/seal"
)

func main() {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	enc.SetEscapeHTML(false)
	if err := enc.Encode(seal.Generate()); err != nil {
		panic(err)
	}
}
