module http

fn (mut c H2MuxConn) send_body_on_stream(mut s H2MuxStream, body []u8) ! {
	c.wmu.lock()
	c.fmu.lock()
	chunk := c.peer_max_frame
	c.fmu.unlock()
	c.write_frame(H2DataFrame{
		stream_id: s.id
		data:      body[..chunk]
	})!
	c.wmu.unlock()
}
