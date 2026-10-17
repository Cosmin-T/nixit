package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"time"
)

// runWatchMode streams metrics continuously as newline-delimited JSON (one full
// MetricsSnapshot per line) using a single warm Collector, so rate metrics
// (network, disk IO) stay accurate across ticks.
func runWatchMode(interval time.Duration) {
	runWatchStdout(interval)
}

func runWatchStdout(interval time.Duration) {
	collector := NewCollector(processWatchOptionsFromFlags())
	runWatchLoop(os.Stdout, collector, interval, time.Sleep)
}

// runWatchLoop emits the first snapshot immediately (so the consumer paints
// without waiting a full interval), then mirrors the TUI cadence: the first
// usable fast snapshot is followed by an immediate full snapshot, and later
// ticks wait for the configured interval after each collection finishes. It
// returns as soon as a write to w fails, which in production means stdout
// closed (parent process gone); sleep is a seam so tests can skip real waits.
func runWatchLoop(w io.Writer, collector *Collector, interval time.Duration, sleep func(time.Duration)) {
	enc := json.NewEncoder(w)
	var schedule collectionSchedule

	for {
		result := collector.collectMode(schedule.nextMode(time.Now()))
		delay := schedule.recordCompletion(result, interval)
		if result.err != nil {
			fmt.Fprintf(os.Stderr, "status: collect failed: %v\n", result.err)
		}
		if !result.data.CollectedAt.IsZero() {
			if err := enc.Encode(result.data); err != nil {
				return
			}
		}
		sleep(delay)
	}
}
