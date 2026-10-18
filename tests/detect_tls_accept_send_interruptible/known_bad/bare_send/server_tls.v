module http

fn (mut s Server) accept_loop(mut ch chan &net.TcpConn) {
	for s.state == .running {
		mut conn := s.listener.accept() or { continue }
		ch <- conn
	}
	ch.close()
	s.close_idle()
}
