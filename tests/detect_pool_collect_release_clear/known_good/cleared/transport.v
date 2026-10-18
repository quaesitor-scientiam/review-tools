module http

pub fn (mut t Transport) close_idle() {
	t.mu.lock()
	mut victims := []&H2Conn{}
	for _, c in t.h2_conns {
		victims << c
	}
	t.h2_conns.clear()
	t.mu.unlock()
	for mut c in victims {
		c.release()
	}
}
