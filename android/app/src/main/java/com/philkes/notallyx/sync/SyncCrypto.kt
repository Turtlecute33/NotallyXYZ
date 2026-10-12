package com.philkes.notallyx.sync

import android.util.Base64
import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream
import java.security.GeneralSecurityException
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Client crypto of the NotallyXYZ sync protocol (see PROTOCOL.md in the server repository). */
object SyncCrypto {

    const val KEY_SIZE = 32
    const val SALT_SIZE = 32
    const val CHUNK_SIZE = 65536
    const val TAG_SIZE = 16
    private const val VERSION: Byte = 1
    private const val MIN_PADDED = 256L
    private const val ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

    private val random = SecureRandom()

    class Keys(val authToken: ByteArray, val encKey: ByteArray, val idKey: ByteArray) {
        val bearer: String =
            Base64.encodeToString(authToken, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
    }

    fun newSyncKey(): ByteArray = ByteArray(KEY_SIZE).also { random.nextBytes(it) }

    fun deriveKeys(syncKey: ByteArray) =
        Keys(
            hkdf(syncKey, null, "notallyxyz/v1/auth"),
            hkdf(syncKey, null, "notallyxyz/v1/enc"),
            hkdf(syncKey, null, "notallyxyz/v1/id"),
        )

    private fun checksum(key: ByteArray): ByteArray =
        sha256("notallyxyz/v1/key-check".toByteArray() + key).copyOf(3)

    /** Display form: Crockford base32 of key and checksum, in groups of 4. */
    fun formatKey(key: ByteArray): String {
        val data = key + checksum(key)
        val out = StringBuilder()
        var buffer = 0
        var bits = 0
        for (byte in data) {
            buffer = (buffer shl 8) or (byte.toInt() and 0xff)
            bits += 8
            while (bits >= 5) {
                out.append(ALPHABET[(buffer shr (bits - 5)) and 31])
                bits -= 5
            }
        }
        if (bits > 0) out.append(ALPHABET[(buffer shl (5 - bits)) and 31])
        return out.chunked(4).joinToString("-")
    }

    /** Returns the 32-byte key, or null if [text] is not a valid key. */
    fun parseKey(text: String): ByteArray? {
        val clean =
            text
                .filterNot { it.isWhitespace() || it == '-' }
                .uppercase()
                .replace('O', '0')
                .replace('I', '1')
                .replace('L', '1')
        if (clean.length != 56) return null
        val out = ByteArray(35)
        var buffer = 0
        var bits = 0
        var index = 0
        for (char in clean) {
            val value = ALPHABET.indexOf(char)
            if (value < 0) return null
            buffer = (buffer shl 5) or value
            bits += 5
            if (bits >= 8) {
                out[index++] = (buffer shr (bits - 8)).toByte()
                bits -= 8
            }
        }
        val key = out.copyOf(KEY_SIZE)
        if (!MessageDigest.isEqual(out.copyOfRange(KEY_SIZE, 35), checksum(key))) return null
        return key
    }

    fun sha256(data: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(data)

    private fun hmac(key: ByteArray, vararg parts: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        parts.forEach { mac.update(it) }
        return mac.doFinal()
    }

    /** HKDF-SHA256 (RFC 5869). An empty salt means 32 zero bytes. */
    fun hkdf(ikm: ByteArray, salt: ByteArray?, info: String, length: Int = 32): ByteArray {
        val prk = hmac(if (salt == null || salt.isEmpty()) ByteArray(32) else salt, ikm)
        val out = ByteArray(length)
        var block = ByteArray(0)
        var pos = 0
        var counter = 1
        while (pos < length) {
            block = hmac(prk, block, info.toByteArray(), byteArrayOf(counter.toByte()))
            val n = minOf(block.size, length - pos)
            System.arraycopy(block, 0, out, pos, n)
            pos += n
            counter++
        }
        return out
    }

    private fun hmacId(idKey: ByteArray, message: String) =
        hmac(idKey, message.toByteArray()).copyOf(16).toHex()

    fun labelId(idKey: ByteArray, value: String) = hmacId(idKey, "label:$value")

    fun blobId(idKey: ByteArray, localName: String) = hmacId(idKey, "blob:$localName")

    fun newRecordId(): String = ByteArray(16).also { random.nextBytes(it) }.toHex()

    fun padme(length: Long): Long {
        if (length < 2) return length
        val e = 63 - java.lang.Long.numberOfLeadingZeros(length)
        val s = 63 - java.lang.Long.numberOfLeadingZeros(e.toLong()) + 1
        val mask = (1L shl (e - s)) - 1
        return (length + mask) and mask.inv()
    }

    fun paddedSize(length: Long) = maxOf(MIN_PADDED, padme(8 + length))

    fun sealedSize(length: Long): Long {
        val padded = paddedSize(length)
        return 1 + SALT_SIZE + padded + TAG_SIZE * ((padded + CHUNK_SIZE - 1) / CHUNK_SIZE)
    }

    fun ad(kind: String, id: String) = "notallyxyz/v1|$kind|$id".toByteArray()

    private fun nonce(index: Int, last: Boolean) =
        ByteArray(12).also {
            it[7] = (index ushr 24).toByte()
            it[8] = (index ushr 16).toByte()
            it[9] = (index ushr 8).toByte()
            it[10] = index.toByte()
            if (last) it[11] = 1
        }

    private class ChunkCipher(encKey: ByteArray, salt: ByteArray, private val ad: ByteArray) {
        private val key = SecretKeySpec(hkdf(encKey, salt, "notallyxyz/v1/seal"), "AES")
        private val cipher = Cipher.getInstance("AES/GCM/NoPadding")

        fun run(mode: Int, index: Int, last: Boolean, input: ByteArray, length: Int): ByteArray {
            cipher.init(mode, key, GCMParameterSpec(TAG_SIZE * 8, nonce(index, last)))
            cipher.updateAAD(ad)
            return cipher.doFinal(input, 0, length)
        }
    }

    /** Encrypts [length] bytes from [input] into [output]. Writes exactly [sealedSize] bytes. */
    fun sealStream(
        encKey: ByteArray,
        ad: ByteArray,
        input: InputStream,
        length: Long,
        output: OutputStream,
        salt: ByteArray = ByteArray(SALT_SIZE).also { random.nextBytes(it) },
    ) {
        val padded = paddedSize(length)
        val chunks = ((padded + CHUNK_SIZE - 1) / CHUNK_SIZE).toInt()
        val cipher = ChunkCipher(encKey, salt, ad)
        output.write(VERSION.toInt())
        output.write(salt)
        val buffer = ByteArray(CHUNK_SIZE)
        var remaining = length
        for (index in 0 until chunks) {
            val size = minOf(CHUNK_SIZE.toLong(), padded - index.toLong() * CHUNK_SIZE).toInt()
            var offset = 0
            if (index == 0) {
                for (i in 0 until 8) buffer[i] = (length ushr (56 - 8 * i)).toByte()
                offset = 8
            }
            val toRead = minOf(remaining, (size - offset).toLong()).toInt()
            readFully(input, buffer, offset, toRead)
            remaining -= toRead
            buffer.fill(0, offset + toRead, size)
            output.write(cipher.run(Cipher.ENCRYPT_MODE, index, index == chunks - 1, buffer, size))
        }
    }

    /** Decrypts into [output] and returns the plaintext length. Throws on any tampering. */
    fun openStream(
        encKey: ByteArray,
        ad: ByteArray,
        input: InputStream,
        output: OutputStream,
    ): Long {
        val header = ByteArray(1 + SALT_SIZE)
        if (readAtMost(input, header) != header.size || header[0] != VERSION) {
            throw GeneralSecurityException("Invalid sealed data")
        }
        val cipher = ChunkCipher(encKey, header.copyOfRange(1, header.size), ad)
        var current = ByteArray(CHUNK_SIZE + TAG_SIZE)
        var next = ByteArray(CHUNK_SIZE + TAG_SIZE)
        var currentSize = readAtMost(input, current)
        var index = 0
        var length = -1L
        var written = 0L
        while (true) {
            if (currentSize <= TAG_SIZE) throw GeneralSecurityException("Invalid sealed data")
            val nextSize = if (currentSize == current.size) readAtMost(input, next) else 0
            val last = nextSize == 0
            val plain = cipher.run(Cipher.DECRYPT_MODE, index, last, current, currentSize)
            var offset = 0
            if (index == 0) {
                if (plain.size < 8) throw GeneralSecurityException("Invalid sealed data")
                length = 0
                for (i in 0 until 8) length = (length shl 8) or (plain[i].toLong() and 0xff)
                if (length < 0) throw GeneralSecurityException("Invalid sealed data")
                offset = 8
            }
            val data = minOf((plain.size - offset).toLong(), length - written).toInt()
            output.write(plain, offset, data)
            written += data
            for (i in offset + data until plain.size) {
                if (plain[i].toInt() != 0) throw GeneralSecurityException("Invalid padding")
            }
            if (last) break
            val swap = current
            current = next
            next = swap
            currentSize = nextSize
            index++
        }
        if (written != length) throw GeneralSecurityException("Truncated sealed data")
        return length
    }

    fun seal(
        encKey: ByteArray,
        ad: ByteArray,
        plain: ByteArray,
        salt: ByteArray? = null,
    ): ByteArray {
        val out = java.io.ByteArrayOutputStream(sealedSize(plain.size.toLong()).toInt())
        if (salt == null) {
            sealStream(encKey, ad, plain.inputStream(), plain.size.toLong(), out)
        } else {
            sealStream(encKey, ad, plain.inputStream(), plain.size.toLong(), out, salt)
        }
        return out.toByteArray()
    }

    fun open(encKey: ByteArray, ad: ByteArray, sealed: ByteArray): ByteArray {
        val out = java.io.ByteArrayOutputStream(maxOf(0, sealed.size - 1 - SALT_SIZE))
        openStream(encKey, ad, sealed.inputStream(), out)
        return out.toByteArray()
    }

    private fun readFully(input: InputStream, buffer: ByteArray, offset: Int, length: Int) {
        if (readAtMost(input, buffer, offset, length) != length) throw EOFException()
    }

    private fun readAtMost(
        input: InputStream,
        buffer: ByteArray,
        offset: Int = 0,
        length: Int = buffer.size,
    ): Int {
        var total = 0
        while (total < length) {
            val n = input.read(buffer, offset + total, length - total)
            if (n < 0) break
            total += n
        }
        return total
    }
}

fun ByteArray.toHex(): String {
    val chars = "0123456789abcdef"
    val out = CharArray(size * 2)
    forEachIndexed { i, b ->
        out[i * 2] = chars[(b.toInt() shr 4) and 15]
        out[i * 2 + 1] = chars[b.toInt() and 15]
    }
    return String(out)
}
