module github.com/omacom/try-omarchy-windows/app

go 1.27

require github.com/klauspost/compress v1.19.2

require github.com/omacom/try-omarchy-windows/networkpayload v0.0.0

replace github.com/omacom/try-omarchy-windows/networkpayload => ../scripts/network
