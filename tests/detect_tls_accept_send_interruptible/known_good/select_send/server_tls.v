module http

fn (mut s Server) accept_loop(mut ch chan &net.TcpConn) {
	for s.state == .running {
		mut conn := s.listener.accept() or { continue }
		mut queued := false
		for !queued && s.state == .running {
			select {
				ch <- conn {
					queued = true
				}
				100 * time.millisecond {}
			}
		}
		if !queued {
			conn.close() or {}
		}
	}
	ch.close()
	s.close_idle()
}
