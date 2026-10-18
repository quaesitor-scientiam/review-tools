module http

fn (mut t Transport) evict_oldest_idle_locked() {
	if t.total_idle_locked() + t.h2_conns.len <= t.max_idle_conns {
		return
	}
	for k, mut c in t.h2_conns {
		if c.active_streams == 0 {
			t.h2_conns.delete(k)
			return
		}
	}
}
