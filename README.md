## Alpine-Homebrew Shim

This project provides Homebrew utilities to processes running in Alpine containers by running virtualized macOS via QEMU.

--- 

- `docker build -t alpine-homebrew-shim .`
- `docker run --rm --name shim-container -p 4444:4444 -p 4445:4445 alpine-homebrew-shim`

---
#### tests
- `./test.sh`
- `curl -X POST http://127.0.0.1:4445 -d "brew install firefox"`