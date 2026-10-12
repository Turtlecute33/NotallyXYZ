package main

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/zalando/go-keyring"
)

// paths: settings in the config folder; the sealed cache in the data folder.
// NOTALLYXYZ_HOME puts everything into one folder and keeps the key in a file (portable use, tests).
type paths struct {
	config, data string
	keyFileOnly  bool
}

func appPaths() paths {
	if home := os.Getenv("NOTALLYXYZ_HOME"); home != "" {
		return paths{config: home, data: home, keyFileOnly: true}
	}
	config, err := os.UserConfigDir()
	if err != nil {
		config = os.TempDir()
	}
	var data string
	switch runtime.GOOS {
	case "windows":
		data = os.Getenv("LOCALAPPDATA")
	case "darwin":
		data = config
	default:
		data = os.Getenv("XDG_DATA_HOME")
		if home, err := os.UserHomeDir(); data == "" && err == nil {
			data = filepath.Join(home, ".local", "share")
		}
	}
	if data == "" {
		data = config
	}
	name := "NotallyXYZ"
	if runtime.GOOS == "darwin" {
		name = "NotallyXYZ Desktop" // apart from the native macOS app
	}
	return paths{config: filepath.Join(config, name), data: filepath.Join(data, name)}
}

func (p paths) settingsFile() string { return filepath.Join(p.config, "settings.json") }
func (p paths) configFile() string   { return filepath.Join(p.config, "config.json") }
func (p paths) keyFile() string      { return filepath.Join(p.config, "sync-key") }
func (p paths) cacheDir() string     { return filepath.Join(p.data, "cache") }

// The sync key goes into the system key store (Secret Service on Linux, Credential Manager on
// Windows). Without one, it goes into a file that only this user can read.
const keyringService, keyringUser = "NotallyXYZ", "sync-key"

func saveKey(p paths, key string) (inFile bool, err error) {
	if !p.keyFileOnly && keyring.Set(keyringService, keyringUser, key) == nil {
		_ = os.Remove(p.keyFile())
		return false, nil
	}
	if err := os.MkdirAll(p.config, 0o700); err != nil {
		return true, err
	}
	return true, os.WriteFile(p.keyFile(), []byte(key+"\n"), 0o600)
}

func loadKey(p paths) (key string, inFile bool, err error) {
	if !p.keyFileOnly {
		if key, err := keyring.Get(keyringService, keyringUser); err == nil {
			return key, false, nil
		}
	}
	b, err := os.ReadFile(p.keyFile())
	if err != nil {
		return "", false, errors.New("no sync key")
	}
	return strings.TrimSpace(string(b)), true, nil
}

func deleteKey(p paths) {
	if !p.keyFileOnly {
		_ = keyring.Delete(keyringService, keyringUser)
	}
	_ = os.Remove(p.keyFile())
}
