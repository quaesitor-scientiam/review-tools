module http

fn (mut c H2Conn) read_response(fields []HpackField) ! {
	for f in fields {
		if err := h2_response_field_error(f.name) {
			return error(err)
		}
	}
}

fn (mut c H2Conn) read_trailers(fields []HpackField) ! {
	for f in fields {
		if err := h2_response_field_error(f.name) {
			return error(err)
		}
		c.trailers[f.name] = f.value
	}
}
