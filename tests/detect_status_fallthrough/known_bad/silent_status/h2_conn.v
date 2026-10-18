module http

fn (mut c H2Conn) read_response() !Response {
	mut got_headers := false
	for f in c.fields {
		if f.name == ':status' {
			if f.value.all_digits() {
				c.resp.status_code = f.value.int()
			}
		}
	}
	got_headers = true
	return c.resp
}
