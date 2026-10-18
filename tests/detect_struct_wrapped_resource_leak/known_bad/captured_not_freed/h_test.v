module main

import crypto.ecdsa

struct FakeServer {
	priv_key ecdsa.PrivateKey
}

fn make_server() (FakeServer, int) {
	return FakeServer{
		priv_key: ecdsa.PrivateKey.new() or { panic(err) }
	}, 1
}

fn test_server() {
	server, n := make_server()
	assert n == 1
}
