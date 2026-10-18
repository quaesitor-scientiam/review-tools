module http

import net.ssl

struct TlsAdapter {
mut:
	conn &ssl.SSLConn
}

fn (mut a TlsAdapter) write(buf []u8) !int {
	return a.conn.write(buf)!
}
