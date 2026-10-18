module http

fn (mut c H2MuxConn) on_response_data(frame H2Frame) ! {
	c.conn_recv_window -= frame.flow_size
	if frame.flow_size > 0 {
		c.send_window_update(frame.stream_id, frame.flow_size)!
	}
}
