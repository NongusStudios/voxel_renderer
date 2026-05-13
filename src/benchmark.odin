package main

import "core:time"
// A metric is a collection of time readings, and a total of every reading
Metric :: struct {
    reading_count: int,
    total: time.Duration,
    min_reading: time.Duration,
    max_reading: time.Duration,
    last_reading: time.Duration,
    start_time:  time.Time,
    started: bool,
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

benchmark_get_metric :: proc(metric: string) -> Metric {
    assert(metric in self.metrics)
    return self.metrics[metric]
}

init_benchmark :: proc() {
    self.metrics = make(map[string]Metric)
}

destroy_benchmark :: proc() {
    delete(self.metrics)
}

benchmark_add_metric :: proc(name: string) {
    self.metrics[name] = {
        min_reading = max(time.Duration),
    }
}

// starts a time reading for a metric
benchmark_start_reading :: proc(metric: string) {
    m := get_metric(metric)
    m.start_time = time.now()
    m.started = true
}

// adds the time reading since start_reading was called to the metric
benchmark_end_reading :: proc(metric: string) {
    m := get_metric(metric)
    if !m.started { return }

    since := time.since(m.start_time)
    m.total += since
    m.reading_count += 1
    m.last_reading = since

    m.min_reading = min(m.min_reading, since)
    m.max_reading = max(m.max_reading, since)
    m.started = false
}

benchmark_get_metric_total :: proc(metric: string) -> time.Duration {
    return get_metric(metric).total
}

benchmark_get_metric_avg :: proc(metric: string) -> time.Duration {
    m := get_metric(metric)
    
    if m.reading_count == 0 { return 0 }
    return m.total / time.Duration(m.reading_count)
}

benchmark_get_metric_last_reading :: proc(metric: string) -> time.Duration {
    m := get_metric(metric)
    return m.last_reading
}

benchmark_get_metric_min_max :: proc(metric: string) -> (min, max: time.Duration) {
    m := get_metric(metric)
    return m.min_reading, m.max_reading
}

benchmark_clear_metric :: proc(metric: string) {
    m := get_metric(metric)
    m^ = {
        min_reading = max(time.Duration),
    }
}
