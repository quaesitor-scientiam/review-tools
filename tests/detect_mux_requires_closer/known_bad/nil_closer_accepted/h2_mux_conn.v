module http

pub fn new_h2_mux_conn(transport H2Transport, close_transport fn ()) &H2MuxConn {
	mut c := &H2MuxConn{
		transport:       transport
		close_transport: close_transport
	}
	spawn c.read_loop()
	return c
}
