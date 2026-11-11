`nacl-fast.min.js` is TweetNaCl.js 1.0.3 (public domain, https://github.com/dchest/tweetnacl-js),
unmodified (npm integrity sha512-6rt+RN7aOi1nGMyC4Xa5DdYiukl2UWCbcJft7YhxReBGQD7OAM8Pbxw6YMo4r2diNEA8FEmu32YOn9rhaiE5yw==).
The Apple TV serves it to the phone/computer pairing page (see PhonePairingServer.swift):
browsers only expose WebCrypto on HTTPS, and the pairing page is plain HTTP on the local network.
