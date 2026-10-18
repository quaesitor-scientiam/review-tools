module http

fn (mut c H2Conn) read_response() !Response {
	mut got_headers := false
	for {
		frame := c.next_frame()!
		match frame {
			H2HeadersFrame {
				if got_headers && !frame.end_stream {
					return error('trailers without END_STREAM')
				}
				status := c.parse_status(frame)!
				if status < 100 || status > 599 || status == 101 {
					return error('invalid :status')
				}
				c.resp.status_code = status
				got_headers = true
			}
			H2DataFrame {
				if !got_headers {
					return error('DATA before response HEADERS')
				}
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
