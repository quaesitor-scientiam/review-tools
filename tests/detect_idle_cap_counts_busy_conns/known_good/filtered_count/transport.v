module http

fn (mut t Transport) evict_oldest_idle_locked() {
	mut idle_h2 := 0
	for _, c in t.h2_conns {
		if c.active_streams == 0 {
			idle_h2++
		}
	}
	if t.total_idle_locked() + idle_h2 <= t.max_idle_conns {
		return
	}
	for k, mut c in t.h2_conns {
		if c.active_streams == 0 {
			t.h2_conns.delete(k)
			return
		}
	}
}
