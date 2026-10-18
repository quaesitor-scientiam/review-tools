module http

fn (mut c H2MuxConn) on_response_data(frame H2Frame) ! {
	c.conn_recv_window -= frame.flow_size
	c.send_window_update(frame.stream_id, frame.data.len)!
}
