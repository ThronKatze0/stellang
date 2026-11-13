// Known-answer tests for StellaOS's crypto (run by tests/e2e.rs: stellaos_crypto, inside QEMU).
// The RSA and ECDSA signatures were made with Python's `cryptography`; the rest are RFC/NIST vectors.

import kernel
import sha2
import x25519
import aead
import rsa
import ecc
import x509

const RSA_N = "ac9c7a9833ee3d2d4a55ecd57cae3f8806cfba6b07be5cfd9fb9add518cb3133cba0652c24ace4ea11a4bb6677120885951179d9af0637f377d2aa13a3c8c98c57358051477b466d2c85c7fbed68be54f1d3ce7a33d69afd663fd5640b84c3447736fce8b8d6c7c6a7bcde784c16e6a6d21a9644391bddfb2167b6b3264cac61e748bb0a5cfc936ff1bbfc240a6c25e3edefd57e17688e5209b96470652b5e3da500e592db36dea061d7613f7e1fbbb98996f6bccf931cdf0f942bc2dba82c8767c3482c363eb43d69124fca6812251e2b22da68f78466ab8de140ff20b08bde132f6f16475daa5818ef0a0571f31074df558b3757abac3cb1be85253a15ed9d"
const RSA_PKCS1 = "2bad56eb80f9f1076218b92566d08c253b6036667ce14778856705fca908450c74cf8a71b568ff37f18a420f6ce176e37d1c2509c92c640588a40070908f75e9c9fd48b5cefcd3a8d6a95aa16c50d5c971cecad31b8f6c2bfd2dd2c00052a6b29cd441a1867765c2fdb996b946d30d5c892d6e217097d461b50d49b8a0c2312dea79b5ee7a0b41f27fe6380dbc12b92a80ba712f9b748957e827360611b76342428a723ce0daa109622f3d7cba2cd7ab94f34d11ee86e618e8073653f1cab1a48c81243c1f5f6a17b7e405df6c5563b7a30e27f8cb558b6faa1cff3d00a2654b2ac7968db8fc49300f265f1a38adb56c568aef08365cb46acd3be2c176a2f515"
const RSA_PSS = "18c34e3d200c9eff6fbe62593f7cd900eb52781f0063e661bf9f285bcd72c6091fc4f8d2d66c9c89c156ed6ec6b0a999003db088120d85ff03b64bcad0f23120b43a4a17ec76d42c238c18b5c1d810f1fc5d6cbe8acab5e4b68445c1034283a30b2d8a18f13fda52b98efcc7de438aadfaad3c7561445cc1eae1b507b3348dcfd753fd8a86d609df67a30fc82e96372519af7d8201572262ff47b97efa0218045ed396d1562cdb3fc36a48b16ff8ac31f075cf1bfdb40d4e9b52645313725126d43cb5bd5759f85e68ed31fdf7982e00ee4ba09c74a2c6770ce298458d96408ccb7aa008d5f8b897db6126752bcdcd07c437a71d2142734403d0832545a3746a"
const P256_KEY = "04f433eefe0ee0a596a520fd50fbc11b96a4ecc9a5446798b3e581daef5457e7af1ed1ecdcf11857733602477fb9b83833506a8ea29dd2f7d32f1ad5086ffdba7c"
const P256_R = "d8949c36a1179db0f1a602cb500f214b889a5ba3ec516ba9337c43bd6c46a8db"
const P256_S = "1298a0554d3123528b23f5dbda82a7eeb3dcea06e13146ceb5bbb2e7d1817ebd"
const P384_KEY = "04b5a5ac7a9de0eeee29b90d15a550d038f0528ed1595429d7a9c7b694e93d259bfad3f509ab609a2d155c9939fdbe1e15796ccba06802e723671a5c156b1258ba6ee502e39620b485fcb798d8679b44cafdb72ae1859a630e75c645d5af24c7be"
const P384_R = "5e60b706261dd7948bf5511211db9cbcf1c22b188b0bffa0bc5769f6f4b2b630a42d65ab128e003ee69882e5080a4bc9"
const P384_S = "8525ff07375d17a7f64b27128d5f0228938faf572c94c09eb1a1cd4c7d7f7c8d2abaeab906ac1cfa3f882b548463cc26"

fn check(name: str, good: bool) {
    println("${if good { "ok" } else { "FAIL" }} ${name}")
}

fn main() {
    let h = sha2.hex
    let b = sha2.bytes_of
    let u = sha2.unhex
    check("sha256", h(sha2.sha256(b("abc"))) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    check("sha384", h(sha2.sha384(b("abc"))) == "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7")
    check("hmac-sha256", h(sha2.hmac256(b("key"), b("The quick brown fox jumps over the lazy dog"))) == "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
    check("x25519", h(x25519.public_key(u("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"))) == "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
    // RFC 8439 2.8.2
    let key = u("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
    let nonce = u("070000004041424344454647")
    let aad = u("50515253c0c1c2c3c4c5c6c7")
    let msg = b("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.")
    let c = aead.aead("chacha", key)
    let sealed = c.seal(nonce, aad, msg)
    check("chacha20-poly1305", h(sealed.slice(sealed.len() - 16, sealed.len())) == "1ae10b594f09e26a7e902ecbd0600691")
    // NIST GCM test case 4 (AES-128)
    let g = aead.aead("aes", u("feffe9928665731c6d6a8f9467308308"))
    let gs = g.seal(u("cafebabefacedbaddecaf888"), u("feedfacedeadbeeffeedfacedeadbeefabaddad2"), u("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39"))
    check("aes-128-gcm", h(gs) == "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e0915bc94fbc3221a5db94fae95ae7121a47")
    gs[0] = gs[0] ^ 1
    check("aes-128-gcm refuses tampering", g.open(u("cafebabefacedbaddecaf888"), u("feedfacedeadbeeffeedfacedeadbeefabaddad2"), gs).is_none())
    check("chacha20-poly1305 opens", (c.open(nonce, aad, sealed) ?? []).len() == msg.len())
    let m = b("hello stellaos")
    let other = b("hello stellaOS")
    let e = [1, 0, 1]
    check("rsa pkcs1", rsa.verify_pkcs1(u(RSA_N), e, "sha256", sha2.sha256(m), u(RSA_PKCS1)))
    check("rsa pkcs1 wrong message", !rsa.verify_pkcs1(u(RSA_N), e, "sha256", sha2.sha256(other), u(RSA_PKCS1)))
    check("rsa pss", rsa.verify_pss(u(RSA_N), e, "sha256", sha2.sha256(m), u(RSA_PSS)))
    check("rsa pss wrong message", !rsa.verify_pss(u(RSA_N), e, "sha256", sha2.sha256(other), u(RSA_PSS)))
    let p256 = ecc.curve("P-256")
    check("ecdsa p-256", ecc.verify(p256, u(P256_KEY), sha2.sha256(m), u(P256_R), u(P256_S)))
    check("ecdsa p-256 wrong message", !ecc.verify(p256, u(P256_KEY), sha2.sha256(other), u(P256_R), u(P256_S)))
    let p384 = ecc.curve("P-384")
    check("ecdsa p-384", ecc.verify(p384, u(P384_KEY), sha2.sha384(m), u(P384_R), u(P384_S)))
    check("ecdsa p-384 swapped r and s", !ecc.verify(p384, u(P384_KEY), sha2.sha384(m), u(P384_S), u(P384_R)))
    // malformed certificates are errors, not crashes
    check("x509 garbage", x509.parse([0x30, 0x82, 0xff, 0xff, 1, 2, 3]).error != "")
    check("x509 empty", x509.parse([]).error != "")
    println("done")
}
