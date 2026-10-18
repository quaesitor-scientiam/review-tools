module http

fn (mut c H2ServerConn) finalize_headers(sid u32, block []u8) ! {
	headers := c.decoder.decode(block) or {
		c.send_goaway(.compression_error)!
		return error('hpack decode failed: ${err}')
	}
	c.dispatch(sid, headers)
}
