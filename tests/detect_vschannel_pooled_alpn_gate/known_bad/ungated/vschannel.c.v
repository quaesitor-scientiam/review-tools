module http

fn h2_dial_probe_vschannel(host string, port int) !ProbeResult {
	mut t := new_vschannel_pooled_transport(host, port)!
	return ProbeResult{
		is_h2: t.negotiated_h2()
	}
}
