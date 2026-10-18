module http

fn (mut c H2MuxConn) apply_peer_settings(settings []H2Setting) {
	for st in settings {
		match st.id {
			.h2_settings_header_table_size {
				c.peer_table_size = st.value
				c.encoder.pending_max_table_size = st.value
			}
			else {}
		}
	}
}
