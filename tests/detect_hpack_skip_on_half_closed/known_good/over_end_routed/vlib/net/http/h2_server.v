module http

struct H2ServerStream {
mut:
	end_stream_seen bool
	over_end        bool
}

fn (mut c H2ServerConn) on_headers(mut s H2ServerStream, frame H2HeadersFrame) ! {
	if s.end_stream_seen {
		s.over_end = true
		return c.on_trailers(mut s, frame)
	}
	c.decode_block(frame.block)!
}
