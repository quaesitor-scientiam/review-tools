module http

fn (mut c H2MuxConn) send_body_on_stream(mut s H2MuxStream, body []u8) ! {
	c.wmu.lock()
	c.fmu.lock()
	mut chunk := c.peer_max_frame
	if s.send_window < 0 {
		chunk = 0
	}
	c.fmu.unlock()
	c.write_frame(H2DataFrame{
		stream_id: s.id
		data:      body[..chunk]
	})!
	c.wmu.unlock()
}
