module main

import crypto.sha256
import os

// pch_key names a precompiled header by the compiler, its arguments, the include environment
// and the working folder a relative -I is resolved against.
fn pch_key(identity string, args []string) string {
	env := ['CPATH', 'C_INCLUDE_PATH', 'INCLUDE', 'PATH'].map('${it}=${os.getenv(it)}')
	return sha256.hexhash(identity + '\n' + args.join('\n') + '\n' + env.join('\n') + '\n' +
		os.getwd())
}
