module http

fn (c &H2ServerConn) classify_stream(id u32) StreamState {
	if id in c.locally_reset {
		return .closed
	}
	return .idle
}

fn (mut c H2ServerConn) dispatch_frame(frame H2Frame) ! {
	if frame is H2PriorityFrame && frame.stream_id !in c.locally_reset {
		return error('self dependency')
	}
}
