module http

fn (mut c H2Conn) read_response() !Response {
	mut got_headers := false
	for {
		frame := c.next_frame()!
		match frame {
			H2HeadersFrame {
				status := c.parse_status(frame)!
				c.resp.status_code = status
				got_headers = true
			}
			H2DataFrame {
				c.resp.body << frame.data
			}
			else {}
		}
		if frame.end_stream {
			break
		}
	}
	return c.resp
}
