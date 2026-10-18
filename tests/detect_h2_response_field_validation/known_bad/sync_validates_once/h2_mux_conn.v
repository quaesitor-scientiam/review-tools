module http

fn (mut c H2MuxConn) on_response_headers(fields []HpackField) ! {
	for f in fields {
		if err := h2_response_field_error(f.name) {
			return error(err)
		}
	}
}

fn (mut c H2MuxConn) on_trailers(fields []HpackField) ! {
	for f in fields {
		if err := h2_response_field_error(f.name) {
			return error(err)
		}
	}
}
