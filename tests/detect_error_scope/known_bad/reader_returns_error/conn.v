module http

fn (mut c H2MuxConn) on_response_data(frame H2Frame) ! {
	if frame.flow_size > c.stream_recv_window(frame.stream_id) {
		return error('stream flow-control window exceeded')
	}
}
