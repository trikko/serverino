/*
Copyright (c) 2023-2026 Andrea Fontana

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.
*/
module serverino.tls;

version(serverino_enable_https):

import serverino.common;
import serverino.config : DaemonConfig;
import std.socket : Socket, socket_t;
import std.string : toStringz;
import std.experimental.logger : info, warning, error;

// Import OpenSSL headers via ImportC
import serverino.openssl_headers;

// Constants for TLS errors
package enum TlsWantRead  = 0x7100;
package enum TlsWantWrite = 0x7101;

package class TlsContext
{
    private:
    SSL_CTX* default_ctx;
    SSL_CTX*[] extra_ctxs;
    size_t valid = 0;
    size_t invalid = 0;

    extern(C) static int sni_callback(SSL* ssl, int* ad, void* arg)
    {
        const(char)* servername = SSL_get_servername(ssl, TLSEXT_NAMETYPE_host_name);
        if (servername is null) return D_SSL_TLSEXT_ERR_OK;

        TlsContext self = cast(TlsContext)arg;
        import std.string : fromStringz;
        string name = cast(string)fromStringz(servername);

        foreach(ctx; self.extra_ctxs)
        {
            X509* cert = SSL_CTX_get0_certificate(ctx);
            if (cert && match_hostname(cert, name))
            {
                SSL_set_SSL_CTX(ssl, ctx);
                return D_SSL_TLSEXT_ERR_OK;
            }
        }

        return D_SSL_TLSEXT_ERR_OK;
    }

    static bool match_hostname(X509* cert, string hostname)
    {
        // Simple hostname matching (CN or SAN)
        // For a real-world implementation, this should be more robust
        // OpenSSL's X509_check_host is available in newer versions
        import std.string : toStringz;
        return X509_check_host(cert, hostname.ptr, hostname.length, 0, null) > 0;
    }

    public:
    this(DaemonConfig.HttpsCertificate[] certificates)
    {
        if (certificates.length == 0) return;

        foreach(i, certInfo; certificates)
        {
            invalid++;

            SSL_CTX* ctx = SSL_CTX_new(TLS_server_method());
            if (ctx is null)
            {
                error("SSL_CTX_new failed");
                continue;
            }

            bool fileOk = true;
            foreach(path; [certInfo.certPath, certInfo.keyPath])
            {
                import std.file : exists;
                if (!exists(path))
                {
                    error("Certificate or key file not found: ", path);
                    fileOk = false;
                }
            }

            if (fileOk == false){
                SSL_CTX_free(ctx);
                continue;
            } 

            if (SSL_CTX_use_certificate_chain_file(ctx, certInfo.certPath.toStringz) <= 0)
            {
                error("SSL_CTX_use_certificate_chain_file failed for ", certInfo.certPath);
                SSL_CTX_free(ctx);
                continue;
            }

            if (SSL_CTX_use_PrivateKey_file(ctx, certInfo.keyPath.toStringz, D_SSL_FILETYPE_PEM) <= 0)
            {
                error("SSL_CTX_use_PrivateKey_file failed for ", certInfo.keyPath);
                SSL_CTX_free(ctx);
                continue;
            }

            if (SSL_CTX_check_private_key(ctx) <= 0)
            {
                error("SSL_CTX_check_private_key failed for ", certInfo.certPath);
                SSL_CTX_free(ctx);
                continue;
            }

            invalid--;
            valid++;
            if (default_ctx is null) default_ctx = ctx;
            else extra_ctxs ~= ctx;
        }

        if (default_ctx !is null)
        {
            SSL_CTX_set_tlsext_servername_callback(default_ctx, &sni_callback);
            SSL_CTX_set_tlsext_servername_arg(default_ctx, cast(void*)this);
        }
    }

    ~this()
    {
        if (default_ctx !is null) SSL_CTX_free(default_ctx);
        foreach(ctx; extra_ctxs) SSL_CTX_free(ctx);
    }

    bool isValid() { return valid>0; }
    size_t validCount() { return valid; }
    size_t invalidCount() { return invalid; }

    
}

package class TlsStream
{
    private:
    SSL* ssl;
    Socket socket;
    bool handshakeComplete = false;

    public:
    this(TlsContext context, Socket s)
    {
        this.socket = s;
        ssl = SSL_new(context.default_ctx);
        SSL_set_fd(ssl, cast(int)s.handle);
    }

    ~this()
    {
        if (ssl !is null) SSL_free(ssl);
    }

    int handshake()
    {
        if (handshakeComplete) return 0;
        
        int ret = SSL_accept(ssl);
        if (ret == 1)
        {
            handshakeComplete = true;
            return 0;
        }
        
        int err = SSL_get_error(ssl, ret);
        if (err == D_SSL_ERROR_WANT_READ) return TlsWantRead;
        if (err == D_SSL_ERROR_WANT_WRITE) return TlsWantWrite;
        
        version(none)
        {
            // Handshake failed, try to get the requested servername for logging
            const(char)* servername = SSL_get_servername(ssl, TLSEXT_NAMETYPE_host_name);
            if (servername !is null)
            {
                import std.string : fromStringz;
                string name = cast(string)fromStringz(servername);
                warning("TLS handshake failed for domain: ", name);
            }
            else warning("TLS handshake failed for unknown/invalid domain");
        }

        // Handshake failed.
        return -1;
    }

    bool isHandshakeComplete() { return handshakeComplete; }

    ptrdiff_t read(ubyte[] buffer)
    {
        import std.socket : Socket;
        int ret = SSL_read(ssl, buffer.ptr, cast(int)buffer.length);
        if (ret > 0) return cast(ptrdiff_t)ret;
        
        int err = SSL_get_error(ssl, ret);
        if (err == D_SSL_ERROR_WANT_READ || err == D_SSL_ERROR_WANT_WRITE) return Socket.ERROR;
        
        return ret; // Error or connection closed
    }

    ptrdiff_t write(const(ubyte)[] buffer)
    {
        import std.socket : Socket;
        int ret = SSL_write(ssl, buffer.ptr, cast(int)buffer.length);
        if (ret > 0) return cast(ptrdiff_t)ret;
        
        int err = SSL_get_error(ssl, ret);
        if (err == D_SSL_ERROR_WANT_READ || err == D_SSL_ERROR_WANT_WRITE) return Socket.ERROR;
        
        return ret;
    }

    void close()
    {
        SSL_shutdown(ssl);
    }
}
