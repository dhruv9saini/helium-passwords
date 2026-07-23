package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"

	"github.com/dhruv9saini/helium-sync/internal/tabjournal"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "helium-tab-journal:", err)
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
	case "restore-catalog":
		return restoreCatalog(args[1:])
	case "validate-catalog":
		return validateCatalog(args[1:])
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
	storePath := flags.String("store", "", "independent journal generation store")
	journalRoot := flags.String("journal-root", "", "native append-only journal root")
	device := flags.String("device", "", "source device")
	profile := flags.String("profile", "", "logical profile namespace")
	protected := flags.Bool("protected", false, "protect a restore-drill generation")
	if err := flags.Parse(args); err != nil {
		return err
	}
	store, err := tabjournal.Open(*storePath)
	if err != nil {
		return err
	}
	manifest, err := store.Capture(tabjournal.CaptureRequest{
		JournalRoot: *journalRoot,
		Device:      *device,
		Profile:     *profile,
		Protected:   *protected,
	})
	if err != nil {
		return err
	}
	return printJSON(manifest)
}

func validate(args []string) error {
	flags := flag.NewFlagSet("validate", flag.ContinueOnError)
	storePath := flags.String("store", "", "independent journal generation store")
	generation := flags.String("generation", "", "generation")
	if err := flags.Parse(args); err != nil {
		return err
	}
	store, err := tabjournal.Open(*storePath)
	if err != nil {
		return err
	}
	manifest, err := store.Validate(*generation)
	if err != nil {
		return err
	}
	return printJSON(manifest)
}

func restoreCatalog(args []string) error {
	flags := flag.NewFlagSet("restore-catalog", flag.ContinueOnError)
	storePath := flags.String("store", "", "independent journal generation store")
	generation := flags.String("generation", "", "generation")
	root := flags.String("disposable-root", "", "marked disposable recovery root")
	profile := flags.String("profile", "", "new drill-journal-* directory")
	if err := flags.Parse(args); err != nil {
		return err
	}
	store, err := tabjournal.Open(*storePath)
	if err != nil {
		return err
	}
	destination, err := store.RestoreCatalog(*generation, *root, *profile)
	if err != nil {
		return err
	}
	return printJSON(map[string]string{
		"destination": destination,
		"state":       "prepared-not-opened",
	})
}

func validateCatalog(args []string) error {
	flags := flag.NewFlagSet("validate-catalog", flag.ContinueOnError)
	destination := flags.String("destination", "", "prepared recovery catalog")
	if err := flags.Parse(args); err != nil {
		return err
	}
	receipt, err := tabjournal.ValidateCatalog(*destination)
	if err != nil {
		return err
	}
	return printJSON(receipt)
}

func retention(args []string, apply bool) error {
	flags := flag.NewFlagSet("retention", flag.ContinueOnError)
	storePath := flags.String("store", "", "independent journal generation store")
	if err := flags.Parse(args); err != nil {
		return err
	}
	store, err := tabjournal.Open(*storePath)
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
	return printJSON(plan)
}

func printJSON(value any) error {
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(value)
}

func usageError() error {
	return errors.New("usage: helium-tab-journal <capture|validate|restore-catalog|validate-catalog|retention-plan|retention-apply> [flags]")
}
