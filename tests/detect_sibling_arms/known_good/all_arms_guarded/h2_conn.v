module http

fn (mut c H2Conn) dispatch_frame(frame H2Frame) {
	match frame {
		H2SettingsFrame {
			if !c.handshaked {
				return
			}
			c.apply_settings(frame)
		}
		H2PingFrame {
			if !c.handshaked {
				return
			}
			c.send_pong(frame)
		}
	}
}
