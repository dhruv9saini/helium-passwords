package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/dhruv9saini/helium-sync/internal/tabsnapshot"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "helium-tabs:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		return usageError()
	}
	switch args[0] {
	case "capture":
		return capture(args[1:])
	case "validate":
		return validate(args[1:])
	case "list":
		return list(args[1:])
	case "restore":
		return restore(args[1:])
	case "validate-restore":
		return validateRestore(args[1:])
	case "prepare-browser-profile":
		return prepareBrowserProfile(args[1:])
	case "validate-browser-profile":
		return validateBrowserProfile(args[1:])
	case "validate-browser-state":
		return validateBrowserState(args[1:])
	case "quarantine":
		return quarantine(args[1:])
	case "retention-plan":
		return retention(args[1:], false)
	case "retention-apply":
		return retention(args[1:], true)
	default:
		return usageError()
	}
}

func capture(args []string) error {
	flags := flag.NewFlagSet("capture", flag.ContinueOnError)
	root := flags.String("store", "", "independent snapshot store")
	input := flags.String("input", "", "browser-API session JSON")
	device := flags.String("device", "", "device name")
	profile := flags.String("profile", "", "logical profile name")
	browser := flags.String("browser-version", "", "Helium version")
	chromium := flags.String("chromium-version", "", "Chromium version")
	reason := flags.String("reason", "scheduled", "capture reason")
	protected := flags.Bool("protected", false, "protect as a known-good drill generation")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *input == "" {
		return errors.New("capture requires --input browser-API JSON; profile paths are not accepted")
	}
	file, err := os.Open(*input)
	if err != nil {
		return fmt.Errorf("open session input: %w", err)
	}
	defer file.Close()
	var session tabsnapshot.Session
	decoder := json.NewDecoder(file)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&session); err != nil {
		return fmt.Errorf("decode session input: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("decode session input: trailing JSON value")
		}
		return fmt.Errorf("decode session input trailer: %w", err)
	}
	store, err := tabsnapshot.Open(*root)
	if err != nil {
		return err
	}
	manifest, err := store.Capture(tabsnapshot.CaptureRequest{
		Device:          *device,
		Profile:         *profile,
		BrowserVersion:  *browser,
		ChromiumVersion: *chromium,
		Reason:          *reason,
		Protected:       *protected,
		Session:         session,
	})
	if err != nil {
		return err
	}
	return writeJSON(manifest)
}

func validate(args []string) error {
	root, generation, err := storeGenerationFlags("validate", args)
	if err != nil {
		return err
	}
	store, err := tabsnapshot.Open(root)
	if err != nil {
		return err
	}
	manifest, err := store.Validate(generation)
	if err != nil {
		return err
	}
	return writeJSON(manifest)
}

func list(args []string) error {
	flags := flag.NewFlagSet("list", flag.ContinueOnError)
	root := flags.String("store", "", "independent snapshot store")
	if err := flags.Parse(args); err != nil {
		return err
	}
	store, err := tabsnapshot.Open(*root)
	if err != nil {
		return err
	}
	items, err := store.List()
	if err != nil {
		return err
	}
	return writeJSON(items)
}

func restore(args []string) error {
	flags := flag.NewFlagSet("restore", flag.ContinueOnError)
	root := flags.String("store", "", "independent snapshot store")
	generation := flags.String("generation", "", "validated generation")
	destination := flags.String("destination", "", "new disposable-state directory")
	if err := flags.Parse(args); err != nil {
		return err
	}
	store, err := tabsnapshot.Open(*root)
	if err != nil {
		return err
	}
	if err := store.Restore(*generation, *destination); err != nil {
		return err
	}
	return writeJSON(map[string]string{"generation": *generation, "destination": *destination})
}

func validateRestore(args []string) error {
	flags := flag.NewFlagSet("validate-restore", flag.ContinueOnError)
	destination := flags.String("destination", "", "disposable-state directory")
	if err := flags.Parse(args); err != nil {
		return err
	}
	manifest, err := tabsnapshot.ValidateRestore(*destination)
	if err != nil {
		return err
	}
	return writeJSON(manifest)
}

func prepareBrowserProfile(args []string) error {
	flags := flag.NewFlagSet("prepare-browser-profile", flag.ContinueOnError)
	restoreDirectory := flags.String("restore", "", "validated neutral restore directory")
	disposableRoot := flags.String("disposable-root", "", "explicitly marked disposable root")
	profile := flags.String("profile", "", "new drill-* profile name")
	if err := flags.Parse(args); err != nil {
		return err
	}
	manifest, destination, err := tabsnapshot.PrepareDisposableBrowserProfile(
		*restoreDirectory, *disposableRoot, *profile)
	if err != nil {
		return err
	}
	return writeJSON(map[string]any{"destination": destination, "manifest": manifest})
}

func validateBrowserProfile(args []string) error {
	flags := flag.NewFlagSet("validate-browser-profile", flag.ContinueOnError)
	directory := flags.String("profile-dir", "", "prepared unopened disposable browser profile")
	if err := flags.Parse(args); err != nil {
		return err
	}
	manifest, err := tabsnapshot.ValidateDisposableBrowserProfile(*directory)
	if err != nil {
		return err
	}
	return writeJSON(manifest)
}

func validateBrowserState(args []string) error {
	flags := flag.NewFlagSet("validate-browser-state", flag.ContinueOnError)
	destination := flags.String("destination", "", "prepared or native post-launch disposable profile")
	if err := flags.Parse(args); err != nil {
		return err
	}
	state, err := tabsnapshot.ValidateBrowserRestoreState(*destination)
	if err != nil {
		return err
	}
	return writeJSON(state)
}

func quarantine(args []string) error {
	flags := flag.NewFlagSet("quarantine", flag.ContinueOnError)
	root := flags.String("store", "", "independent snapshot store")
	generation := flags.String("generation", "", "suspect generation")
	reason := flags.String("reason", "", "short quarantine reason slug")
	if err := flags.Parse(args); err != nil {
		return err
	}
	store, err := tabsnapshot.Open(*root)
	if err != nil {
		return err
	}
	destination, err := store.Quarantine(*generation, *reason)
	if err != nil {
		return err
	}
	return writeJSON(map[string]string{
		"generation": *generation,
		"quarantine": destination,
		"reason":     *reason,
	})
}

func retention(args []string, apply bool) error {
	flags := flag.NewFlagSet("retention", flag.ContinueOnError)
	root := flags.String("store", "", "independent snapshot store")
	if err := flags.Parse(args); err != nil {
		return err
	}
	store, err := tabsnapshot.Open(*root)
	if err != nil {
		return err
	}
	plan, err := store.PlanRetention()
	if err != nil {
		return err
	}
	if apply {
		if err := store.ApplyRetention(plan); err != nil {
			return err
		}
	}
	return writeJSON(plan)
}

func storeGenerationFlags(name string, args []string) (string, string, error) {
	flags := flag.NewFlagSet(name, flag.ContinueOnError)
	root := flags.String("store", "", "independent snapshot store")
	generation := flags.String("generation", "", "generation id")
	if err := flags.Parse(args); err != nil {
		return "", "", err
	}
	return *root, *generation, nil
}

func writeJSON(value any) error {
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(value)
}

func usageError() error {
	return errors.New("usage: helium-tabs <capture|validate|list|restore|validate-restore|prepare-browser-profile|validate-browser-profile|validate-browser-state|quarantine|retention-plan|retention-apply> [flags]")
}
