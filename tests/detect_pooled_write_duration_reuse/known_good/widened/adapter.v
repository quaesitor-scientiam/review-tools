module http

import net.ssl

struct TlsAdapter {
mut:
	conn &ssl.SSLConn
}

fn (mut a TlsAdapter) write(buf []u8) !int {
	a.conn.set_read_timeout(write_stall_budget)
	defer { a.conn.set_read_timeout(read_poll_interval) }
	return a.conn.write(buf)!
}
