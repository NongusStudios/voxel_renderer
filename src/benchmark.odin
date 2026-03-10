package main

import "core:time"
// A metric is a collection of time readings, and a total of every reading
Metric :: struct {
    readings: [dynamic]time.Duration,
    total: time.Duration,
    start_time:  time.Time,
}

@(private="file")
self: struct {
    metrics: map[string]Metric,
}

@(private="file")
get_metric :: #force_inline proc(metric: string) -> ^Metric {
    assert(metric in self.metrics)
    return &self.metrics[metric]
}

init_benchmark :: proc() {
    self.metrics = make(map[string]Metric)
}

destroy_benchmark :: proc() {
    for _, k in self.metrics {
        delete(k.readings)
    }
    delete(self.metrics)
}

benchmark_add_metric :: proc(name: string) {
    self.metrics[name] = {
        readings = make([dynamic]time.Duration),
    }
}

// starts a time reading for a metric
benchmark_start_reading :: proc(metric: string) {
    m := get_metric(metric)
    m.start_time = time.now()
}

// adds the time reading since start_reading was called to the metric
benchmark_end_reading :: proc(metric: string) {
    m := get_metric(metric)
    since := time.since(m.start_time)
    append(&m.readings, since)
    m.total += since
}

benchmark_get_metric_total :: proc(metric: string) -> time.Duration {
    return get_metric(metric).total
}

benchmark_get_metric_avg :: proc(metric: string) -> time.Duration {
    m := get_metric(metric)
    
    n := min(1, len(m.readings))

    return m.total / time.Duration(n)
}

benchmark_get_last_reading :: proc(metric: string) -> time.Duration {
    m := get_metric(metric)
    return m.readings[len(m.readings)-1]
}

benchmark_get_readings :: proc(metric: string) -> []time.Duration {
    assert(metric in self.metrics)
    m := &self.metrics[metric]
    return m.readings[:]
}
