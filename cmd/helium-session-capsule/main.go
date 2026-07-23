package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"time"

	"github.com/dhruv9saini/helium-sync/internal/sessioncapsule"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "helium-session-capsule:", err)
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
	case "quarantine":
		return quarantine(args[1:])
	case "retention-plan":
		return retention(args[1:], false)
	case "retention-apply":
		return retention(args[1:], true)
	case "guard-run":
		return guardRun(args[1:])
	default:
		return usageError()
	}
}

func capture(args []string) error {
	flags := flag.NewFlagSet("capture", flag.ContinueOnError)
	storePath := flags.String("store", "", "raw-session capsule store")
	profileRoot := flags.String("profile-root", "", "Chromium user-data directory")
	guard := flags.String("guard", "", "browser lifetime lock outside the profile")
	device := flags.String("device", "", "source device")
	profile := flags.String("profile", "", "logical profile namespace")
	protected := flags.Bool("protected", false, "protect a restore-drill generation")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("capture accepts flags only")
	}
	store, err := sessioncapsule.Open(*storePath)
	if err != nil {
		return err
	}
	manifest, err := store.Capture(sessioncapsule.CaptureRequest{
		ProfileRoot: *profileRoot,
		GuardPath:   *guard,
		Device:      *device,
		Profile:     *profile,
		CapturedAt:  time.Now().UTC(),
		Protected:   *protected,
	})
	if err != nil {
		return err
	}
	return printJSON(manifest)
}

func validate(args []string) error {
	flags := flag.NewFlagSet("validate", flag.ContinueOnError)
	storePath := flags.String("store", "", "raw-session capsule store")
	generation := flags.String("generation", "", "generation")
	if err := flags.Parse(args); err != nil {
		return err
	}
	store, err := sessioncapsule.Open(*storePath)
	if err != nil {
		return err
	}
	manifest, err := store.Validate(*generation)
	if err != nil {
		return err
	}
	return printJSON(manifest)
}

func list(args []string) error {
	flags := flag.NewFlagSet("list", flag.ContinueOnError)
	storePath := flags.String("store", "", "raw-session capsule store")
	if err := flags.Parse(args); err != nil {
		return err
	}
	store, err := sessioncapsule.Open(*storePath)
	if err != nil {
		return err
	}
	manifests, err := store.List()
	if err != nil {
		return err
	}
	return printJSON(manifests)
}

func restore(args []string) error {
	flags := flag.NewFlagSet("restore", flag.ContinueOnError)
	storePath := flags.String("store", "", "raw-session capsule store")
	generation := flags.String("generation", "", "generation")
	root := flags.String("disposable-root", "", "marked disposable root")
	profile := flags.String("profile", "", "new drill-native-* directory")
	if err := flags.Parse(args); err != nil {
		return err
	}
	store, err := sessioncapsule.Open(*storePath)
	if err != nil {
		return err
	}
	destination, err := store.Restore(*generation, *root, *profile)
	if err != nil {
		return err
	}
	return printJSON(map[string]string{
		"destination": destination,
		"invocation":  "chromium --user-data-dir=DESTINATION --restore-last-session",
	})
}

func validateRestore(args []string) error {
	flags := flag.NewFlagSet("validate-restore", flag.ContinueOnError)
	destination := flags.String("destination", "", "unopened native-session restore")
	if err := flags.Parse(args); err != nil {
		return err
	}
	receipt, err := sessioncapsule.ValidateRestore(*destination)
	if err != nil {
		return err
	}
	return printJSON(receipt)
}

func quarantine(args []string) error {
	flags := flag.NewFlagSet("quarantine", flag.ContinueOnError)
	storePath := flags.String("store", "", "raw-session capsule store")
	generation := flags.String("generation", "", "generation")
	reason := flags.String("reason", "", "reason slug")
	if err := flags.Parse(args); err != nil {
		return err
	}
	store, err := sessioncapsule.Open(*storePath)
	if err != nil {
		return err
	}
	destination, err := store.Quarantine(*generation, *reason)
	if err != nil {
		return err
	}
	return printJSON(map[string]string{"quarantine": destination})
}

func retention(args []string, apply bool) error {
	flags := flag.NewFlagSet("retention", flag.ContinueOnError)
	storePath := flags.String("store", "", "raw-session capsule store")
	if err := flags.Parse(args); err != nil {
		return err
	}
	store, err := sessioncapsule.Open(*storePath)
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

func guardRun(args []string) error {
	flags := flag.NewFlagSet("guard-run", flag.ContinueOnError)
	guard := flags.String("guard", "", "browser lifetime lock outside the profile")
	if err := flags.Parse(args); err != nil {
		return err
	}
	commandArgs := flags.Args()
	if len(commandArgs) == 0 {
		return errors.New("guard-run requires a command after --")
	}
	return sessioncapsule.GuardRun(*guard, func() error {
		command := exec.Command(commandArgs[0], commandArgs[1:]...)
		command.Stdin = os.Stdin
		command.Stdout = os.Stdout
		command.Stderr = os.Stderr
		return command.Run()
	})
}

func printJSON(value any) error {
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(value)
}

func usageError() error {
	return errors.New("usage: helium-session-capsule <capture|validate|list|restore|validate-restore|quarantine|retention-plan|retention-apply|guard-run> [flags]")
}
