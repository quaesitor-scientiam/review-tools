module http

fn (mut c H2MuxConn) apply_peer_settings(settings []H2Setting) {
	for st in settings {
		match st.id {
			.h2_settings_max_frame_size {
				c.wmu.lock()
				c.fmu.lock()
				c.peer_max_frame = st.value
				c.fmu.unlock()
				c.wmu.unlock()
			}
			else {}
		}
	}
}
