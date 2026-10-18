module http

fn (mut c H2MuxConn) on_response_data(frame H2Frame) ! {
	if frame.flow_size > c.stream_recv_window(frame.stream_id) {
		c.reset_stream(frame.stream_id, .flow_control_error)
		return
	}
}

fn (mut c H2MuxConn) do_on_stream(req Request) !Response {
	if c.closed {
		return error('connection closed')
	}
	return c.wait_response(req)
}
