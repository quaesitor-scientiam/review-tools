module http

import net

fn (mut s Server) close_idle(handles []int) {
	for handle in handles {
		net.shutdown(handle) or {}
		$if windows {
			net.close(handle) or {}
		}
	}
}
