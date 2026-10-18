module quic

struct QuicConn {
mut:
	idle_deadline    ?u64
	closing_deadline ?u64
}

fn (c &QuicConn) next_timeout() ?u64 {
	if d := c.idle_deadline {
		return d
	}
	return none
}
