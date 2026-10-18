module http

struct Conn {
mut:
	pending []u8
}

fn (mut c Conn) on_frame(payload []u8) {
	c.pending << payload
}
