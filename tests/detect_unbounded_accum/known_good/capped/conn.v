module http

const max_pending = 65536

struct Conn {
mut:
	pending []u8
}

fn (mut c Conn) on_frame(payload []u8) ! {
	if c.pending.len + payload.len > max_pending {
		return error('too big')
	}
	c.pending << payload
}
