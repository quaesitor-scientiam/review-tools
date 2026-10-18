module http

fn (mut s Server) handle_conn(mut conn TlsConn) {
	defer {
		if s.was_force_closed(conn.handle) {
			conn.owns_socket = false
		}
		conn.shutdown()
	}
	s.serve(mut conn)
}
