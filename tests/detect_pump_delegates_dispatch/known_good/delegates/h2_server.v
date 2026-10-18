module http

fn (mut c H2ServerConn) pump_for_window() ! {
	frame := c.read_frame()!
	c.dispatch_frame(frame)!
}
