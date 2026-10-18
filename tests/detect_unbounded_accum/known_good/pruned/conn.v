module http

struct Conn {
mut:
	streams map[u32]bool
}

fn (mut c Conn) open(id u32) {
	c.streams[id] = true
}

fn (mut c Conn) close(id u32) {
	c.streams.delete(id)
}
