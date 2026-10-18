module http

fn (mut c H2ServerConn) apply_settings(settings []H2Setting) ! {
	for s in settings {
		match s.id {
			h2_settings_initial_window_size {
				delta := i64(s.value) - i64(c.peer.initial_window_size)
				for _, st in c.streams {
					if st.send_window + delta > h2_max_window {
						return error('window overflow')
					}
				}
				c.peer.initial_window_size = s.value
				for _, mut st in c.streams {
					st.send_window += delta
				}
			}
			else {}
		}
	}
}
