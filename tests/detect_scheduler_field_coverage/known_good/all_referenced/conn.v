module quic

struct QuicConn {
mut:
	idle_deadline    ?u64
	closing_deadline ?u64
}

fn (c &QuicConn) next_timeout() ?u64 {
	mut best := ?u64(none)
	if d := c.idle_deadline {
		best = d
	}
	if d := c.closing_deadline {
		best = d
	}
	return best
}
