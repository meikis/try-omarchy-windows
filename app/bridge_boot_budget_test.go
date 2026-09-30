package main

import "testing"

func TestBridgeBootBudgetPreservesPausedVM(t *testing.T) {
	var b bridgeBootBudget
	for i := 0; i < 1000; i++ {
		b.tick()
	}
	if b.ticks != 0 {
		t.Fatal("unknown startup state consumed the budget")
	}
	b.observe(`{"return":{"running":true,"status":"running"}}`)
	for i := 0; i < 200; i++ {
		b.tick()
	}
	b.observe(`{"event":"STOP"}`)
	b.observe(`{"event":"STOP"}`)
	for i := 0; i < 1000; i++ {
		b.tick()
	}
	if b.ticks != 200 || b.expired() {
		t.Fatal("paused VM expired", b)
	}
	b.observe(`{"return":{"running":false,"status":"paused"}}`)
	b.observe(`{"return":{}}`)
	b.observe(`{"event":"UNRELATED"}`)
	b.tick()
	if b.ticks != 200 {
		t.Fatal("unrelated QMP message resumed budget", b)
	}
	b.observe(`{"event":"RESUME"}`)
	for i := 0; i < 99; i++ {
		b.tick()
	}
	if b.expired() {
		t.Fatal("budget expired early")
	}
	b.tick()
	if !b.expired() {
		t.Fatal("running VM never expired")
	}
	b.tick()
	if b.ticks != bridgeBootTimeoutTicks {
		t.Fatal("counter exceeded its bound")
	}
	b.observe(`{"event":"STOP"}`)
	if b.expired() {
		t.Fatal("exhausted budget stopped a manually paused VM")
	}
	b.observe(`{"event":"RESUME"}`)
	if !b.expired() {
		t.Fatal("resuming an unready VM discarded its exhausted budget")
	}
}
