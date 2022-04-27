/* $OpenBSD: tls.h,v 1.61 2022/02/01 17:18:38 jsing Exp $ */
/*
 * Copyright (c) 2014 Joel Sing <jsing@openbsd.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

module serverino.c.libtls;

import core.stdc.config;
import core.sys.posix.sys.select;
import core.sys.posix.sys.types;

extern (C):

/* RFC 6960 Section 2.3 */

/* RFC 6960 Section 2.2 */

/* RFC 5280 Section 5.3.1 */

struct tls;
struct tls_config;

alias tls_read_cb = c_long function (
    tls* _ctx,
    void* _buf,
    size_t _buflen,
    void* _cb_arg);
alias tls_write_cb = c_long function (
    tls* _ctx,
    const(void)* _buf,
    size_t _buflen,
    void* _cb_arg);
alias tls_sign_cb = int function (
    void* _cb_arg,
    const(char)* _pubkey_hash,
    const(ubyte)* _input,
    size_t _input_len,
    int _padding_type,
    ubyte** _out_signature,
    size_t* _out_signature_len);

int tls_init ();

const(char)* tls_config_error (tls_config* _config);
const(char)* tls_error (tls* _ctx);

tls_config* tls_config_new ();
void tls_config_free (tls_config* _config);

const(char)* tls_default_ca_cert_file ();

int tls_config_add_keypair_file (
    tls_config* _config,
    const(char)* _cert_file,
    const(char)* _key_file);
int tls_config_add_keypair_mem (
    tls_config* _config,
    const(ubyte)* _cert,
    size_t _cert_len,
    const(ubyte)* _key,
    size_t _key_len);
int tls_config_add_keypair_ocsp_file (
    tls_config* _config,
    const(char)* _cert_file,
    const(char)* _key_file,
    const(char)* _ocsp_staple_file);
int tls_config_add_keypair_ocsp_mem (
    tls_config* _config,
    const(ubyte)* _cert,
    size_t _cert_len,
    const(ubyte)* _key,
    size_t _key_len,
    const(ubyte)* _staple,
    size_t _staple_len);
int tls_config_set_alpn (tls_config* _config, const(char)* _alpn);
int tls_config_set_ca_file (tls_config* _config, const(char)* _ca_file);
int tls_config_set_ca_path (tls_config* _config, const(char)* _ca_path);
int tls_config_set_ca_mem (tls_config* _config, const(ubyte)* _ca, size_t _len);
int tls_config_set_cert_file (tls_config* _config, const(char)* _cert_file);
int tls_config_set_cert_mem (
    tls_config* _config,
    const(ubyte)* _cert,
    size_t _len);
int tls_config_set_ciphers (tls_config* _config, const(char)* _ciphers);
int tls_config_set_crl_file (tls_config* _config, const(char)* _crl_file);
int tls_config_set_crl_mem (
    tls_config* _config,
    const(ubyte)* _crl,
    size_t _len);
int tls_config_set_dheparams (tls_config* _config, const(char)* _params);
int tls_config_set_ecdhecurve (tls_config* _config, const(char)* _curve);
int tls_config_set_ecdhecurves (tls_config* _config, const(char)* _curves);
int tls_config_set_key_file (tls_config* _config, const(char)* _key_file);
int tls_config_set_key_mem (
    tls_config* _config,
    const(ubyte)* _key,
    size_t _len);
int tls_config_set_keypair_file (
    tls_config* _config,
    const(char)* _cert_file,
    const(char)* _key_file);
int tls_config_set_keypair_mem (
    tls_config* _config,
    const(ubyte)* _cert,
    size_t _cert_len,
    const(ubyte)* _key,
    size_t _key_len);
int tls_config_set_keypair_ocsp_file (
    tls_config* _config,
    const(char)* _cert_file,
    const(char)* _key_file,
    const(char)* _staple_file);
int tls_config_set_keypair_ocsp_mem (
    tls_config* _config,
    const(ubyte)* _cert,
    size_t _cert_len,
    const(ubyte)* _key,
    size_t _key_len,
    const(ubyte)* _staple,
    size_t staple_len);
int tls_config_set_ocsp_staple_mem (
    tls_config* _config,
    const(ubyte)* _staple,
    size_t _len);
int tls_config_set_ocsp_staple_file (
    tls_config* _config,
    const(char)* _staple_file);
int tls_config_set_protocols (tls_config* _config, uint _protocols);
int tls_config_set_session_fd (tls_config* _config, int _session_fd);
int tls_config_set_verify_depth (tls_config* _config, int _verify_depth);
int tls_config_set_sign_cb (
    tls_config* _config,
    tls_sign_cb _cb,
    void* _cb_arg);

void tls_config_prefer_ciphers_client (tls_config* _config);
void tls_config_prefer_ciphers_server (tls_config* _config);

void tls_config_insecure_noverifycert (tls_config* _config);
void tls_config_insecure_noverifyname (tls_config* _config);
void tls_config_insecure_noverifytime (tls_config* _config);
void tls_config_verify (tls_config* _config);

void tls_config_ocsp_require_stapling (tls_config* _config);
void tls_config_verify_client (tls_config* _config);
void tls_config_verify_client_optional (tls_config* _config);

void tls_config_clear_keys (tls_config* _config);
int tls_config_parse_protocols (uint* _protocols, const(char)* _protostr);

int tls_config_set_session_id (
    tls_config* _config,
    const(ubyte)* _session_id,
    size_t _len);
int tls_config_set_session_lifetime (tls_config* _config, int _lifetime);
int tls_config_add_ticket_key (
    tls_config* _config,
    uint _keyrev,
    ubyte* _key,
    size_t _keylen);

tls* tls_client ();
tls* tls_server ();
int tls_configure (tls* _ctx, tls_config* _config);
void tls_reset (tls* _ctx);
void tls_free (tls* _ctx);

int tls_accept_fds (tls* _ctx, tls** _cctx, int _fd_read, int _fd_write);
int tls_accept_socket (tls* _ctx, tls** _cctx, int _socket);
int tls_accept_cbs (
    tls* _ctx,
    tls** _cctx,
    tls_read_cb _read_cb,
    tls_write_cb _write_cb,
    void* _cb_arg);
int tls_connect (tls* _ctx, const(char)* _host, const(char)* _port);
int tls_connect_fds (
    tls* _ctx,
    int _fd_read,
    int _fd_write,
    const(char)* _servername);
int tls_connect_servername (
    tls* _ctx,
    const(char)* _host,
    const(char)* _port,
    const(char)* _servername);
int tls_connect_socket (tls* _ctx, int _s, const(char)* _servername);
int tls_connect_cbs (
    tls* _ctx,
    tls_read_cb _read_cb,
    tls_write_cb _write_cb,
    void* _cb_arg,
    const(char)* _servername);
int tls_handshake (tls* _ctx);
ssize_t tls_read (tls* _ctx, void* _buf, size_t _buflen);
ssize_t tls_write (tls* _ctx, const(void)* _buf, size_t _buflen);
int tls_close (tls* _ctx);

int tls_peer_cert_provided (tls* _ctx);
int tls_peer_cert_contains_name (tls* _ctx, const(char)* _name);

const(char)* tls_peer_cert_hash (tls* _ctx);
const(char)* tls_peer_cert_issuer (tls* _ctx);
const(char)* tls_peer_cert_subject (tls* _ctx);
time_t tls_peer_cert_notbefore (tls* _ctx);
time_t tls_peer_cert_notafter (tls* _ctx);
const(ubyte)* tls_peer_cert_chain_pem (tls* _ctx, size_t* _len);

const(char)* tls_conn_alpn_selected (tls* _ctx);
const(char)* tls_conn_cipher (tls* _ctx);
int tls_conn_cipher_strength (tls* _ctx);
const(char)* tls_conn_servername (tls* _ctx);
int tls_conn_session_resumed (tls* _ctx);
const(char)* tls_conn_version (tls* _ctx);

ubyte* tls_load_file (const(char)* _file, size_t* _len, char* _password);
void tls_unload_file (ubyte* _buf, size_t len);

int tls_ocsp_process_response (
    tls* _ctx,
    const(ubyte)* _response,
    size_t _size);
int tls_peer_ocsp_cert_status (tls* _ctx);
int tls_peer_ocsp_crl_reason (tls* _ctx);
time_t tls_peer_ocsp_next_update (tls* _ctx);
int tls_peer_ocsp_response_status (tls* _ctx);
const(char)* tls_peer_ocsp_result (tls* _ctx);
time_t tls_peer_ocsp_revocation_time (tls* _ctx);
time_t tls_peer_ocsp_this_update (tls* _ctx);
const(char)* tls_peer_ocsp_url (tls* _ctx);

struct tls_signer;
tls_signer* tls_signer_new ();
void tls_signer_free (tls_signer* _signer);
const(char)* tls_signer_error (tls_signer* _signer);
int tls_signer_add_keypair_file (
    tls_signer* _signer,
    const(char)* _cert_file,
    const(char)* _key_file);
int tls_signer_add_keypair_mem (
    tls_signer* _signer,
    const(ubyte)* _cert,
    size_t _cert_len,
    const(ubyte)* _key,
    size_t _key_len);
int tls_signer_sign (
    tls_signer* _signer,
    const(char)* _pubkey_hash,
    const(ubyte)* _input,
    size_t _input_len,
    int _padding_type,
    ubyte** _out_signature,
    size_t* _out_signature_len);
    
enum TLS_API = 20200120;
enum TLS_PROTOCOL_TLSv1_0 = 1 << 1;
enum TLS_PROTOCOL_TLSv1_1 = 1 << 2;
enum TLS_PROTOCOL_TLSv1_2 = 1 << 3;
enum TLS_PROTOCOL_TLSv1_3 = 1 << 4;
enum TLS_PROTOCOL_TLSv1 = TLS_PROTOCOL_TLSv1_0 | TLS_PROTOCOL_TLSv1_1 | TLS_PROTOCOL_TLSv1_2 | TLS_PROTOCOL_TLSv1_3;
enum TLS_PROTOCOLS_ALL = TLS_PROTOCOL_TLSv1;
enum TLS_PROTOCOLS_DEFAULT = TLS_PROTOCOL_TLSv1_2 | TLS_PROTOCOL_TLSv1_3;
enum TLS_WANT_POLLIN = -2;
enum TLS_WANT_POLLOUT = -3;
enum TLS_OCSP_RESPONSE_SUCCESSFUL = 0;
enum TLS_OCSP_RESPONSE_MALFORMED = 1;
enum TLS_OCSP_RESPONSE_INTERNALERROR = 2;
enum TLS_OCSP_RESPONSE_TRYLATER = 3;
enum TLS_OCSP_RESPONSE_SIGREQUIRED = 4;
enum TLS_OCSP_RESPONSE_UNAUTHORIZED = 5;
enum TLS_OCSP_CERT_GOOD = 0;
enum TLS_OCSP_CERT_REVOKED = 1;
enum TLS_OCSP_CERT_UNKNOWN = 2;
enum TLS_CRL_REASON_UNSPECIFIED = 0;
enum TLS_CRL_REASON_KEY_COMPROMISE = 1;
enum TLS_CRL_REASON_CA_COMPROMISE = 2;
enum TLS_CRL_REASON_AFFILIATION_CHANGED = 3;
enum TLS_CRL_REASON_SUPERSEDED = 4;
enum TLS_CRL_REASON_CESSATION_OF_OPERATION = 5;
enum TLS_CRL_REASON_CERTIFICATE_HOLD = 6;
enum TLS_CRL_REASON_REMOVE_FROM_CRL = 8;
enum TLS_CRL_REASON_PRIVILEGE_WITHDRAWN = 9;
enum TLS_CRL_REASON_AA_COMPROMISE = 10;
enum TLS_MAX_SESSION_ID_LENGTH = 32;
enum TLS_TICKET_KEY_SIZE = 48;
enum TLS_PADDING_NONE = 0;
enum TLS_PADDING_RSA_PKCS1 = 1;
enum TLS_PADDING_RSA_X9_31 = 2;

/* HEADER_TLS_H */


version(WithTLS) {
    // Linked with libtls
}
else {
    // Fake implementation of members we need
    import std.traits;
    import std.algorithm : canFind, sort;
    
    alias tlsModule = serverino.c.libtls;

    static immutable toImplement = [
        "tls_accept_socket", "tls_close", "tls_config_free", "tls_config_new", 
        "tls_config_set_cert_mem", "tls_config_set_key_mem", "tls_configure", 
        "tls_free", "tls_handshake", "tls_read", "tls_server", "tls_write"
    ];

    static foreach(sy; __traits(allMembers, tlsModule))
        static if(isFunction!(__traits(getMember, tlsModule,sy)) && toImplement.canFind(sy))
            mixin((ReturnType!(__traits(getMember, tlsModule,sy))).stringof ~ " " ~ sy ~ (Parameters!(__traits(getMember, tlsModule,sy))).stringof ~ `{ assert(0, "TLS is disabled. Use config=WithTLS with dub or set version=WithTLS."); }`);
    
}