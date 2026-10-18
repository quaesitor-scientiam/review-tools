module http

fn (c &H2ServerConn) classify_stream(id u32) StreamState {
	if id in c.locally_reset {
		return .closed
	}
	return .idle
}

fn (mut c H2ServerConn) mark_locally_reset(id u32) {
	if id !in c.locally_reset {
		c.locally_reset << id
	}
}

fn (mut c H2ServerConn) dispatch_frame(frame H2Frame) ! {
	if frame is H2PriorityFrame && c.classify_stream(frame.stream_id) != .closed {
		return error('self dependency')
	}
}
