package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/signal"
	"regexp"
	"strings"
	"syscall"
	"time"
)

const (
	evSyn = 0x00
	evKey = 0x01

	keyLeftMeta  = 125
	keyRightMeta = 126
	keyRightAlt  = 100

	busUSB = 0x03

	uiDevCreate  = 0x5501
	uiDevDestroy = 0x5502
	uiSetEvBit   = 0x40045564
	uiSetKeyBit  = 0x40045565
	eviocgrab    = 0x40044590
)

type inputEvent struct {
	Sec   int64
	Usec  int64
	Type  uint16
	Code  uint16
	Value int32
}

type inputID struct {
	Bus     uint16
	Vendor  uint16
	Product uint16
	Version uint16
}

type uinputUserDev struct {
	Name      [80]byte
	ID        inputID
	FFEffects uint32
	AbsMax    [64]int32
	AbsMin    [64]int32
	AbsFuzz   [64]int32
	AbsFlat   [64]int32
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)

	device := os.Getenv("MAGIC_KEYBOARD_EVENT")
	if device == "" {
		found, err := findMagicKeyboard()
		if err != nil {
			log.Fatalf("find Magic Keyboard: %v", err)
		}
		device = found
	}
	log.Printf("using source device %s", device)

	source, err := os.Open(device)
	if err != nil {
		log.Fatalf("open %s: %v", device, err)
	}
	defer source.Close()

	uinput, err := createKeyboard()
	if err != nil {
		log.Fatalf("create uinput keyboard: %v", err)
	}
	defer func() {
		_, _, _ = syscall.Syscall(syscall.SYS_IOCTL, uinput.Fd(), uiDevDestroy, 0)
		_ = uinput.Close()
	}()

	if err := ioctl(source.Fd(), eviocgrab, 1); err != nil {
		log.Fatalf("grab %s: %v", device, err)
	}
	defer func() { _ = ioctl(source.Fd(), eviocgrab, 0) }()
	log.Printf("grabbed %s; remapping Command to KEY_RIGHTALT", device)

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	go func() {
		<-signals
		os.Exit(0)
	}()

	var event inputEvent
	for {
		if err := binary.Read(source, binary.LittleEndian, &event); err != nil {
			if errors.Is(err, io.EOF) {
				return
			}
			log.Fatalf("read %s: %v", device, err)
		}
		if event.Type == evKey {
			switch event.Code {
			case keyLeftMeta, keyRightMeta:
				event.Code = keyRightAlt
			}
		}
		if event.Type != evSyn && event.Type != evKey {
			continue
		}
		if err := binary.Write(uinput, binary.LittleEndian, event); err != nil {
			log.Fatalf("write uinput: %v", err)
		}
	}
}

func createKeyboard() (*os.File, error) {
	file, err := os.OpenFile("/dev/uinput", os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}

	for _, ev := range []int{evSyn, evKey} {
		if err := ioctl(file.Fd(), uiSetEvBit, uintptr(ev)); err != nil {
			_ = file.Close()
			return nil, fmt.Errorf("set evbit %d: %w", ev, err)
		}
	}
	for key := 1; key <= 255; key++ {
		if err := ioctl(file.Fd(), uiSetKeyBit, uintptr(key)); err != nil {
			_ = file.Close()
			return nil, fmt.Errorf("set keybit %d: %w", key, err)
		}
	}

	var dev uinputUserDev
	copy(dev.Name[:], "Arch Magic Keyboard Remap")
	dev.ID = inputID{Bus: busUSB, Vendor: 0x05ac, Product: 0x0321, Version: 1}
	if err := binary.Write(file, binary.LittleEndian, dev); err != nil {
		_ = file.Close()
		return nil, err
	}
	if err := ioctl(file.Fd(), uiDevCreate, 0); err != nil {
		_ = file.Close()
		return nil, err
	}
	time.Sleep(500 * time.Millisecond)
	return file, nil
}

func findMagicKeyboard() (string, error) {
	data, err := os.ReadFile("/proc/bus/input/devices")
	if err != nil {
		return "", err
	}

	eventRe := regexp.MustCompile(`\bevent[0-9]+\b`)
	for _, block := range bytes.Split(data, []byte("\n\n")) {
		text := string(block)
		if !strings.Contains(text, `Name="Magic Keyboard"`) {
			continue
		}
		if !strings.Contains(text, "Handlers=leds ") {
			continue
		}
		event := eventRe.FindString(text)
		if event == "" {
			continue
		}
		return "/dev/input/" + event, nil
	}
	return "", errors.New("main Magic Keyboard event device not found")
}

func ioctl(fd uintptr, request uintptr, arg uintptr) error {
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, request, arg)
	if errno != 0 {
		return errno
	}
	return nil
}
