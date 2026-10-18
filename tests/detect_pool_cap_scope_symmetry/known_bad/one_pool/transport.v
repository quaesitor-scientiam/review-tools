module http

fn (mut t Transport) evict_idle_if_over_cap() {
	if t.total_idle_locked() <= t.max_idle_conns {
		return
	}
	for k, _ in t.h2_conns {
		t.h2_conns.delete(k)
		return
	}
}
