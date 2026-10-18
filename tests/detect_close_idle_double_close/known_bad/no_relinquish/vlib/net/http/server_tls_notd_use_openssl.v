module http

fn (mut s Server) handle_conn(mut conn TlsConn) {
	defer {
		conn.shutdown()
	}
	s.serve(mut conn)
}
