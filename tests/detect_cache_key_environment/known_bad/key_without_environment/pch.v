module main

import crypto.sha256

// pch_key names a precompiled header by the compiler and its arguments only, so a build with
// another CPATH reuses a header made for the old one.
fn pch_key(identity string, args []string) string {
	return sha256.hexhash(identity + '\n' + args.join('\n'))
}
