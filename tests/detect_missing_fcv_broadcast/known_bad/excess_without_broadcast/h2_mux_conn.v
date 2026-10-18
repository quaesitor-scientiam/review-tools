module http

fn (mut c H2MuxConn) send_body_on_stream(mut s H2MuxStream, body []u8) ! {
	c.fmu.lock()
	excess := c.reserved - body.len
	c.send_window += excess
	c.fmu.unlock()
}
