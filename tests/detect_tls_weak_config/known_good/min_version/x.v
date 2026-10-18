module tls

fn cfg() SslConfig {
	return SslConfig{
		validate:    true
		min_version: .tls1_2
	}
}
