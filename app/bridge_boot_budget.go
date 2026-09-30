package main

import "encoding/json"

// Charge only observed running VM time. A user pause or host suspend must not
// consume the bridge's guest-readiness budget or cause an automatic resume.
const bridgeBootTimeoutTicks = 300

type bridgeBootBudget struct {
	running bool
	ticks   int
}

func (b *bridgeBootBudget) observe(line string) {
	var m qmpMessage
	if json.Unmarshal([]byte(line), &m) != nil {
		return
	}
	switch m.Event {
	case "STOP":
		b.running = false
	case "RESUME":
		b.running = true
	default:
		var status struct {
			Running *bool `json:"running"`
		}
		if len(m.Return) > 0 && json.Unmarshal(m.Return, &status) == nil && status.Running != nil {
			b.running = *status.Running
		}
	}
}
func (b *bridgeBootBudget) tick() {
	if b.running && b.ticks < bridgeBootTimeoutTicks {
		b.ticks++
	}
}
func (b *bridgeBootBudget) expired() bool { return b.running && b.ticks >= bridgeBootTimeoutTicks }
