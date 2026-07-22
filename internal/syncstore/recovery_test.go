package syncstore

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"filippo.io/age"
)

func TestSeedRecoveryRoundTripIsEncryptedBoundAndNoOverwrite(t *testing.T) {
	root := t.TempDir()
	statePath := filepath.Join(root, "d", "client.json")
	tokenPath := filepath.Join(root, "d", "token")
	seed, err := CreateSeedState(statePath)
	if err != nil {
		t.Fatal(err)
	}
	token := "synthetic-recovery-token-000000000000000000000000"
	if err := os.WriteFile(tokenPath, []byte(token+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	publicPath := filepath.Join(root, "seed-public")
	if err := os.WriteFile(publicPath, []byte(seed.SeedSigningPublicKey()+"\n"), 0644); err != nil {
		t.Fatal(err)
	}

	first, _ := age.GenerateX25519Identity()
	second, _ := age.GenerateX25519Identity()
	recipientsPath := filepath.Join(root, "recipients.txt")
	recipients := first.Recipient().String() + "\n" + second.Recipient().String() + "\n"
	if err := os.WriteFile(recipientsPath, []byte(recipients), 0644); err != nil {
		t.Fatal(err)
	}
	identityPath := filepath.Join(root, "identity.txt")
	if err := os.WriteFile(identityPath, []byte(first.String()+"\n"), 0600); err != nil {
		t.Fatal(err)
	}

	exportPath := filepath.Join(root, "copies", "seed-recovery.age")
	receipt, err := ExportSeedRecovery(statePath, tokenPath, recipientsPath, exportPath)
	if err != nil {
		t.Fatal(err)
	}
	if receipt.RecipientCount != 2 || len(receipt.SHA256) != 64 {
		t.Fatalf("unexpected export receipt: %+v", receipt)
	}
	encrypted, _ := os.ReadFile(exportPath)
	stateRaw, _ := os.ReadFile(statePath)
	for _, plaintext := range [][]byte{
		[]byte(token), []byte(seed.SeedSigningPrivate), stateRaw,
	} {
		if bytes.Contains(encrypted, plaintext) {
			t.Fatal("encrypted recovery generation contains plaintext seed material")
		}
	}

	restoredDir := filepath.Join(root, "restored")
	imported, err := ImportSeedRecovery(
		exportPath, identityPath, publicPath, restoredDir)
	if err != nil {
		t.Fatal(err)
	}
	if imported.DeviceID != "d" || imported.ActiveKeyID != seed.ActiveKeyID ||
		imported.SeedSigningPublic != seed.SeedSigningPublic {
		t.Fatalf("unexpected import receipt: %+v", imported)
	}
	restored, err := LoadClientState(filepath.Join(restoredDir, "client.json"))
	if err != nil {
		t.Fatal(err)
	}
	if restored.SeedSigningPrivate != seed.SeedSigningPrivate ||
		restored.Keys[seed.ActiveKeyID] != seed.Keys[seed.ActiveKeyID] {
		t.Fatal("restored seed does not match encrypted source")
	}
	restoredToken, _ := os.ReadFile(filepath.Join(restoredDir, "token"))
	if strings.TrimSpace(string(restoredToken)) != token {
		t.Fatal("restored token does not match encrypted source")
	}
	if _, err := ImportSeedRecovery(exportPath, identityPath, publicPath, restoredDir); err == nil {
		t.Fatal("recovery import replaced an existing directory")
	}
	if _, err := ExportSeedRecovery(statePath, tokenPath, recipientsPath, exportPath); err == nil {
		t.Fatal("recovery export replaced an existing generation")
	}
}

func TestSeedRecoveryRejectsWeakRecipientsWrongAnchorAndCorruption(t *testing.T) {
	root := t.TempDir()
	statePath := filepath.Join(root, "d", "client.json")
	tokenPath := filepath.Join(root, "d", "token")
	seed, _ := CreateSeedState(statePath)
	_ = os.WriteFile(tokenPath, []byte("synthetic-recovery-token-000000000000000000000000\n"), 0600)
	first, _ := age.GenerateX25519Identity()
	second, _ := age.GenerateX25519Identity()
	oneRecipient := filepath.Join(root, "one-recipient")
	_ = os.WriteFile(oneRecipient, []byte(first.Recipient().String()+"\n"), 0644)
	if _, err := ExportSeedRecovery(statePath, tokenPath, oneRecipient,
		filepath.Join(root, "weak.age")); err == nil {
		t.Fatal("single-recipient recovery export was accepted")
	}
	recipients := filepath.Join(root, "recipients")
	_ = os.WriteFile(recipients, []byte(first.Recipient().String()+"\n"+
		second.Recipient().String()+"\n"), 0644)
	exportPath := filepath.Join(root, "recovery.age")
	if _, err := ExportSeedRecovery(statePath, tokenPath, recipients, exportPath); err != nil {
		t.Fatal(err)
	}
	identity := filepath.Join(root, "identity")
	_ = os.WriteFile(identity, []byte(first.String()+"\n"), 0600)
	wrongPublic := filepath.Join(root, "wrong-public")
	_ = os.WriteFile(wrongPublic, []byte("wrong\n"), 0644)
	wrongOutput := filepath.Join(root, "wrong-output")
	if _, err := ImportSeedRecovery(exportPath, identity, wrongPublic, wrongOutput); err == nil {
		t.Fatal("recovery import accepted the wrong trust anchor")
	}
	if _, err := os.Stat(wrongOutput); !os.IsNotExist(err) {
		t.Fatal("failed recovery import created an output directory")
	}

	publicPath := filepath.Join(root, "seed-public")
	_ = os.WriteFile(publicPath, []byte(seed.SeedSigningPublicKey()+"\n"), 0644)
	raw, _ := os.ReadFile(exportPath)
	raw[len(raw)-1] ^= 0x01
	corrupt := filepath.Join(root, "corrupt.age")
	_ = os.WriteFile(corrupt, raw, 0600)
	if _, err := ImportSeedRecovery(corrupt, identity, publicPath,
		filepath.Join(root, "corrupt-output")); err == nil {
		t.Fatal("corrupt recovery generation was accepted")
	}
}

func TestGenerateRecoveryIdentityUsesNewPrivateDirectory(t *testing.T) {
	output := filepath.Join(t.TempDir(), "recovery-media")
	if err := GenerateRecoveryIdentity(output); err != nil {
		t.Fatal(err)
	}
	identityInfo, _ := os.Stat(filepath.Join(output, "identity.txt"))
	recipientRaw, err := os.ReadFile(filepath.Join(output, "recipient.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if identityInfo.Mode().Perm() != 0600 ||
		!strings.HasPrefix(strings.TrimSpace(string(recipientRaw)), "age1") {
		t.Fatal("recovery identity output has wrong mode or recipient")
	}
	if err := GenerateRecoveryIdentity(output); err == nil {
		t.Fatal("recovery identity generation replaced an existing directory")
	}
}

func TestSeedImportsOnlyCompleteMatchingBrowserRevisionBaseline(t *testing.T) {
	statePath := filepath.Join(t.TempDir(), "client.json")
	seed, err := CreateSeedState(statePath)
	if err != nil {
		t.Fatal(err)
	}
	seed.Sequence = 12
	if err := seed.Save(); err != nil {
		t.Fatal(err)
	}
	revisions := map[Kind]map[string]Counter{
		KindPassword: {"password-key": 4},
		KindCookie:   {"cookie-key": 7},
	}
	if err := seed.ImportBrowserRevisionBaseline(12, revisions); err != nil {
		t.Fatal(err)
	}
	reloaded, _ := LoadClientState(statePath)
	if reloaded.revision(KindPassword, "password-key") != 4 ||
		reloaded.revision(KindCookie, "cookie-key") != 7 {
		t.Fatal("browser revision baseline was not persisted")
	}
	if err := reloaded.ImportBrowserRevisionBaseline(11, revisions); err == nil {
		t.Fatal("stale browser cursor was accepted")
	}
	if err := reloaded.ImportBrowserRevisionBaseline(12,
		map[Kind]map[string]Counter{KindPassword: {}}); err == nil {
		t.Fatal("partial browser revision baseline was accepted")
	}
}
