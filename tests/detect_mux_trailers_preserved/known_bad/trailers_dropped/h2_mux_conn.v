module http

fn (mut c H2MuxConn) on_response_headers(mut s H2MuxStream, frame H2HeadersFrame, fields []H2HeaderField) {
	if was_headers_done && !frame.end_stream {
		c.reset_stream(s.id, .protocol_error)
		return
	}
	if was_headers_done {
		s.ended = true
	}
	s.cv.signal()
}
