module main

import crypto.ecdsa

fn test_key() {
	priv := ecdsa.PrivateKey.new()!
	assert priv.sign([u8(1)])!.len > 0
}
