module http

fn (c &H2ServerConn) classify_stream(id u32) StreamState {
	if id in c.streams {
		return .open
	}
	if id <= c.last_stream_id {
		return .closed
	}
	return .idle
}
