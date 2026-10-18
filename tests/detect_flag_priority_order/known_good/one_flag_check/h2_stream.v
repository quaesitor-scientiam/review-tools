module http

fn (mut s H2Stream) finalize_headers() {
	if s.self_dep {
		s.send_rst_stream(.protocol_error)
		return
	}
	s.headers_done = true
}
