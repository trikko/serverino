#define OPENSSL_NO_DEPRECATED
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/bio.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <openssl/evp.h>

enum {
    D_SSL_FILETYPE_PEM = SSL_FILETYPE_PEM,
    D_SSL_ERROR_WANT_READ = SSL_ERROR_WANT_READ,
    D_SSL_ERROR_WANT_WRITE = SSL_ERROR_WANT_WRITE,
    D_SSL_TLSEXT_ERR_OK = SSL_TLSEXT_ERR_OK
};
