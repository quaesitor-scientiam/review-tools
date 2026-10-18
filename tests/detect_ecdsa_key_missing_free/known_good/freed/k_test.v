module main

import crypto.ecdsa

fn test_key() {
	priv := ecdsa.PrivateKey.new()!
	defer { unsafe { priv.free() } }
	assert priv.sign([u8(1)])!.len > 0
}
