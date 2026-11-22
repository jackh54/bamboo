//! Chromium's macOS "v10" value encryption: AES-128-CBC with a key derived
//! from the browser's Keychain "Safe Storage" password.

use aes::Aes128;
use cbc::{
    Decryptor,
    cipher::{BlockModeDecrypt, KeyIvInit, block_padding::Pkcs7},
};
use sha1::Sha1;

use crate::ImportError;

pub(crate) type Key = [u8; 16];

const PREFIX: &[u8] = b"v10";
const SALT: &[u8] = b"saltysalt";
const ITERATIONS: u32 = 1003;
const IV: [u8; 16] = [0x20; 16];

pub(crate) fn derive_key(password: &[u8]) -> Key {
    pbkdf2::pbkdf2_hmac_array::<Sha1, 16>(password, SALT, ITERATIONS)
}

/// Decrypts a `v10`-prefixed value. Cookie plaintext from Chromium 24+ still
/// carries a host hash; the caller strips it.
pub(crate) fn decrypt(key: &Key, value: &[u8]) -> Result<Vec<u8>, ImportError> {
    let ciphertext = value
        .strip_prefix(PREFIX)
        .ok_or_else(|| ImportError::Decryption {
            message: "value does not start with v10".to_string(),
        })?;
    Decryptor::<Aes128>::new_from_slices(key, &IV)
        .map_err(|e| ImportError::Decryption {
            message: e.to_string(),
        })?
        .decrypt_padded_vec::<Pkcs7>(ciphertext)
        .map_err(|e| ImportError::Decryption {
            message: e.to_string(),
        })
}

#[cfg(test)]
pub(crate) fn encrypt(key: &Key, plaintext: &[u8]) -> Vec<u8> {
    use cbc::{Encryptor, cipher::BlockModeEncrypt};

    let mut value = PREFIX.to_vec();
    value.extend(
        Encryptor::<Aes128>::new_from_slices(key, &IV)
            .expect("key and IV have the right length")
            .encrypt_padded_vec::<Pkcs7>(plaintext),
    );
    value
}

#[cfg(test)]
mod tests {
    use super::*;

    // Produced independently with Python's hashlib.pbkdf2_hmac and `openssl enc`.
    const PEANUTS_KEY: Key = [
        0xd9, 0xa0, 0x9d, 0x49, 0x9b, 0x4e, 0x1b, 0x74, 0x61, 0xf2, 0x8e, 0x67, 0x97, 0x2c, 0x6d,
        0xbd,
    ];
    const HELLO_COOKIE: [u8; 16] = [
        0x9b, 0xd0, 0x3a, 0x62, 0x1a, 0x67, 0x7a, 0xee, 0x47, 0x3d, 0x22, 0x74, 0x95, 0x24, 0xaf,
        0x3d,
    ];

    #[test]
    fn derives_the_chromium_key() {
        assert_eq!(derive_key(b"peanuts"), PEANUTS_KEY);
    }

    #[test]
    fn decrypts_a_v10_value() {
        let mut value = b"v10".to_vec();
        value.extend(HELLO_COOKIE);
        assert_eq!(decrypt(&PEANUTS_KEY, &value).unwrap(), b"hello cookie");
    }

    #[test]
    fn round_trips_through_the_test_encryptor() {
        let encrypted = encrypt(&PEANUTS_KEY, b"another value that spans two blocks");
        assert_eq!(
            decrypt(&PEANUTS_KEY, &encrypted).unwrap(),
            b"another value that spans two blocks"
        );
    }

    #[test]
    fn rejects_values_without_the_v10_prefix() {
        assert!(matches!(
            decrypt(&PEANUTS_KEY, &HELLO_COOKIE),
            Err(ImportError::Decryption { .. })
        ));
    }

    #[test]
    fn rejects_ciphertext_that_is_not_block_aligned() {
        assert!(matches!(
            decrypt(&PEANUTS_KEY, b"v10short"),
            Err(ImportError::Decryption { .. })
        ));
    }
}
