module http

import net.ssl

struct TlsAdapter {
mut:
	conn &ssl.SSLConn
	sock &net.TcpConn
}

fn (mut a TlsAdapter) read(mut buf []u8) !int {
	return a.conn.read(mut buf)!
}
