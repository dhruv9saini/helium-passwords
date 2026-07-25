package main

import "testing"

func TestValidateListenAcceptsOnlyLoopbackOrTailnetIP(t *testing.T) {
	for _, listen := range []string{
		"127.0.0.1:44719",
		"[::1]:44719",
		"100.100.105.47:44719",
	} {
		if err := validateListen(listen); err != nil {
			t.Fatalf("%s was rejected: %v", listen, err)
		}
	}
	for _, listen := range []string{
		"0.0.0.0:44719",
		"192.168.4.233:44719",
		"lm.tail0168aa.ts.net:44719",
		"100.64.0.1",
	} {
		if err := validateListen(listen); err == nil {
			t.Fatalf("%s was accepted", listen)
		}
	}
}
