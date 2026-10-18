module http

fn (mut c H2Conn) on_headers(fields []HpackField) ! {
	for f in fields {
		if f.name == 'content-length' {
			if f.value.all_digits() {
				c.content_length = f.value.int()
				c.has_content_length = true
			} else {
				return error('malformed content-length: ${f.value}')
			}
		}
	}
}
