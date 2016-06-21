# ruby-h2

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

