module http

fn (mut c H2MuxConn) send_header_block_locked(stream_id u32, block []u8) ! {
	c.fmu.lock()
	max_frame := c.peer_max_frame
	c.fmu.unlock()
	if block.len <= max_frame {
		c.write_frame(H2HeadersFrame{
			stream_id: stream_id
			block:     block
		})!
		return
	}
	c.write_frame(H2HeadersFrame{
		stream_id: stream_id
		block:     block[..max_frame]
	})!
	c.send_continuations(stream_id, block[max_frame..])!
}
