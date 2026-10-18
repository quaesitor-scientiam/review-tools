module http

fn (mut c H2MuxConn) dispatch_frame(frame H2Frame) {
	match frame {
		H2GoawayFrame {
			c.wmu.lock()
			c.smu.lock()
			c.goaway = true
			c.smu.unlock()
			c.wmu.unlock()
		}
		else {}
	}
}
