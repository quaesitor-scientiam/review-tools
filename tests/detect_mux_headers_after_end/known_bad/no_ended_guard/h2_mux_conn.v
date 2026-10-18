module http

fn (mut c H2MuxConn) on_response_headers(mut s H2MuxStream, frame H2HeadersFrame) {
	s.mu.lock()
	defer { s.mu.unlock() }
	was_headers_done := s.headers_done
	if was_headers_done {
		s.ended = frame.end_stream
		return
	}
	s.headers_done = true
}
