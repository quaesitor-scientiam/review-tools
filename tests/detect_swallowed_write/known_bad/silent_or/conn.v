module http

fn (mut c H2MuxConn) on_idle() {
	c.send_ping(c.ping_payload) or {}
}
