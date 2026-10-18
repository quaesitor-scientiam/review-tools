module http

fn (mut c H2Conn) read_response() !Response {
	for {
		frame := c.next_frame()!
		status := c.parse_status(frame)!
		if status >= 100 && status < 200 {
			if frame.end_stream {
				return error('1xx interim response must not carry END_STREAM')
			}
			continue
		}
		if frame.end_stream {
			break
		}
	}
	return c.resp
}
