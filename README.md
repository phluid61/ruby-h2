# ruby-h2

[![Test](https://github.com/phluid61/ruby-h2/actions/workflows/test.yml/badge.svg)](https://github.com/phluid61/ruby-h2/actions/workflows/test.yml)
[![Contributor Covenant](https://img.shields.io/badge/Contributor%20Covenant-v3.0%20adopted-ff69b4.svg)](code_of_conduct.md)

A pure ruby HTTP/2 library.

There's a demo server in `demo-site.rb` which runs a basic HTTP/2
server.  Full HTTPS compatibility requires that Ruby was built with
OpenSSL version 1.0.2+ (for ALPN and SNI).  You should also have a
valid X.509 certificate and key in the same directory.

    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout private.key \
      -out certificate.crt \
      -days 3650

By default the demo site serves the following resources:

* `https://localhost:8888/` - a simple HTML page

* `https://localhost:8888/padded` - as above, but uses HTTP/2 padding
   on HEADERS and DATA frames in the response

The server sends a valid 404 response for any other resource, and a 405
for any request method other than GET or HEAD.

|            |                                              |
|------------|----------------------------------------------|
| Repository | <https://github.com/phluid61/ruby-h2/>       |
| Issues     | <https://github.com/phluid61/ruby-h2/issues> |
| Webpage    | <https://phluid61.github.io/ruby-h2/>        |


## Contributing

We require all contributors to comply with the [Developer Certificate of Origin](https://developercertificate.org/). This ensures that all contributions are properly licensed and attributed.


## Contributor Code of Conduct

This repository is subject to a [Contributor Code of Conduct](code_of_conduct.md)
adapted from the [Contributor Covenant][cc], version 3.0, available at
<https://www.contributor-covenant.org/version/3/0/>


[cc]: https://www.contributor-covenant.org


## Licence

This project is licensed under the ISC licence. See [LICENSE](LICENSE)
for details.
