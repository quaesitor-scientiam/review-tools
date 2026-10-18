module http

import net.ssl

struct H1PooledConn {
mut:
	ssl ssl.SSLConn
}
