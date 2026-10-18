module http

fn (mut c H2ServerConn) pump_for_window() ! {
	frame := c.read_frame()!
	match frame {
		H2WindowUpdateFrame { c.on_window_update(frame)! }
		H2RstStreamFrame { c.on_rst(frame)! }
		else {}
	}
}
