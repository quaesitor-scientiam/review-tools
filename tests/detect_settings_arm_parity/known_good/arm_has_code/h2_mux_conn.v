module http

fn (mut c H2MuxConn) apply_peer_settings(s H2Settings) {
	for id, v in s.entries {
		match id {
			h2_settings_header_table_size {
				c.encoder.set_max_table_size(v)
			}
			h2_settings_max_frame_size {
				c.max_frame_size = v
			}
			else {}
		}
	}
}
