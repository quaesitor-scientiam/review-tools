module http

pub fn new_h2_mux_conn(transport H2Transport, close_transport fn ()) &H2MuxConn {
	if close_transport == unsafe { nil } {
		panic('new_h2_mux_conn: close_transport must not be nil')
	}
	mut c := &H2MuxConn{
		transport:       transport
		close_transport: close_transport
	}
	spawn c.read_loop()
	return c
}
