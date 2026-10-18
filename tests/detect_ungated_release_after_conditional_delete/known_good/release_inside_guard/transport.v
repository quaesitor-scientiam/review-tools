module http

fn (mut t Transport) evict_idle(key string, mut conn H2MuxConn) {
	t.mu.lock()
	existing := t.h2_conns[key] or { conn }
	if voidptr(existing) == voidptr(conn) {
		t.h2_conns.delete(key)
		conn.release()
	}
	t.mu.unlock()
}
