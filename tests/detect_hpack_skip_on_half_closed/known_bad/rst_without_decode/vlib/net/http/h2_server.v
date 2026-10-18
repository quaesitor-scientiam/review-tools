module http

struct H2ServerStream {
mut:
	end_stream_seen bool
}

fn (mut c H2ServerConn) on_headers(mut s H2ServerStream, frame H2HeadersFrame) ! {
	if s.end_stream_seen {
		c.reset_stream(frame.stream_id, .stream_closed)!
		return
	}
	c.decode_block(frame.block)!
}
