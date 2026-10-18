module http

fn (mut c H2ServerConn) finalize_headers(sid u32, block []u8) ! {
	headers := c.decoder.decode(block) or {
		c.send_rst_stream(sid, .compression_error)!
		return
	}
	c.dispatch(sid, headers)
}
