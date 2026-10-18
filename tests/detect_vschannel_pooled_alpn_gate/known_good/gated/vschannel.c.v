module http

fn h2_dial_probe_vschannel(host string, port int) !ProbeResult {
	if C.vschannel_alpn_supported() == 0 {
		return ProbeResult{
			is_h2: false
		}
	}
	mut t := new_vschannel_pooled_transport(host, port)!
	return ProbeResult{
		is_h2: t.negotiated_h2()
	}
}
