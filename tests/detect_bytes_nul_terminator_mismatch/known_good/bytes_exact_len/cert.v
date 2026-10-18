module main

fn parse_pem(cert string) int {
	buf := cert.bytes()
	return C.mbedtls_x509_crt_parse_der(&crt, buf.data, buf.len)
}
