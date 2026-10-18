module http

fn (mut c H2ServerConn) dispatch_frame(frame H2Frame) ! {
	if c.awaiting_cont != 0 {
		if frame !is H2ContinuationFrame || frame.stream_id != c.awaiting_cont {
			return error('expected CONTINUATION')
		}
	} else if frame is H2ContinuationFrame {
		return error('orphan CONTINUATION')
	}
	match frame {
		H2ContinuationFrame { c.on_continuation(frame)! }
		else {}
	}
}
