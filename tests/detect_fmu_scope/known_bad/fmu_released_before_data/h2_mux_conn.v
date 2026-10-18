module http

fn (mut c H2MuxConn) send_body_on_stream(mut s H2MuxStream, body []u8) ! {
	c.fmu.lock()
	max_frame := c.peer_max_frame
	c.fmu.unlock()
	c.wmu.lock()
	c.write_frame(H2DataFrame{
		stream_id: s.id
		data:      body[..max_frame]
	})!
	c.wmu.unlock()
}
