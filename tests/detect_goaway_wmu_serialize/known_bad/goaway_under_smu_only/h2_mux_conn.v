module http

fn (mut c H2MuxConn) dispatch_frame(frame H2Frame) {
	match frame {
		H2GoawayFrame {
			c.smu.lock()
			c.goaway = true
			c.smu.unlock()
		}
		else {}
	}
}
