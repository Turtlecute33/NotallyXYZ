package com.philkes.notallyx.sync

import java.io.ByteArrayOutputStream
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Checks the crypto against testvectors.json from the server repository (shared by all clients).
 */
@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [35])
class SyncCryptoTest {

    private val vectors = JSONObject(javaClass.getResource("/sync/testvectors.json")!!.readText())

    private fun hex(s: String) =
        ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    @Test
    fun keysAndIds() {
        val key = hex(vectors.getString("syncKey"))
        assertEquals(vectors.getString("display"), SyncCrypto.formatKey(key))
        assertArrayEquals(key, SyncCrypto.parseKey(vectors.getString("display")))
        assertArrayEquals(
            key,
            SyncCrypto.parseKey(
                " " + vectors.getString("display").lowercase().replace('0', 'o') + "\n"
            ),
        )
        val keys = SyncCrypto.deriveKeys(key)
        assertEquals(vectors.getString("authTokenBase64Url"), keys.bearer)
        assertEquals(vectors.getString("encKey"), keys.encKey.toHex())
        assertEquals(vectors.getString("idKey"), keys.idKey.toHex())
        val labels = vectors.getJSONObject("labelIds")
        labels.keys().forEach {
            assertEquals(labels.getString(it), SyncCrypto.labelId(keys.idKey, it))
        }
        val blobs = vectors.getJSONObject("blobIds")
        blobs.keys().forEach {
            assertEquals(blobs.getString(it), SyncCrypto.blobId(keys.idKey, it))
        }
    }

    @Test
    fun keyTypoIsRejected() {
        val display = vectors.getString("display")
        val typo = (if (display[0] == 'A') 'B' else 'A') + display.substring(1)
        assertNull(SyncCrypto.parseKey(typo))
        assertNull(SyncCrypto.parseKey(display.dropLast(1)))
        assertNull(SyncCrypto.parseKey("U" + display.substring(1)))
    }

    @Test
    fun sizes() {
        val padme = vectors.getJSONObject("padme")
        padme.keys().forEach { assertEquals(padme.getLong(it), SyncCrypto.padme(it.toLong())) }
        val sealed = vectors.getJSONObject("sealedSize")
        sealed.keys().forEach {
            assertEquals(sealed.getLong(it), SyncCrypto.sealedSize(it.toLong()))
        }
    }

    @Test
    fun sealVectors() {
        val encKey = hex(vectors.getString("encKey"))
        val list = vectors.getJSONArray("seal")
        for (i in 0 until list.length()) {
            val v = list.getJSONObject(i)
            val ad = SyncCrypto.ad(v.getString("kind"), v.getString("id"))
            val plain = hex(v.getString("plain"))
            val sealed = hex(v.getString("sealed"))
            assertArrayEquals(v.getString("name"), plain, SyncCrypto.open(encKey, ad, sealed))
            assertArrayEquals(
                v.getString("name"),
                sealed,
                SyncCrypto.seal(encKey, ad, plain, hex(v.getString("salt"))),
            )
            // Wrong context, flipped byte and truncation must fail.
            val otherKind = if (v.getString("kind") == "label") "note" else "label"
            assertThrows(Exception::class.java) {
                SyncCrypto.open(encKey, SyncCrypto.ad(otherKind, v.getString("id")), sealed)
            }
            val flipped =
                sealed.copyOf().also { it[it.size - 1] = (it[it.size - 1].toInt() xor 1).toByte() }
            assertThrows(Exception::class.java) { SyncCrypto.open(encKey, ad, flipped) }
            if (sealed.size > 1 + 32 + 65552) {
                assertThrows(Exception::class.java) {
                    SyncCrypto.open(encKey, ad, sealed.copyOf(1 + 32 + 65552))
                }
            }
        }
    }

    @Test
    fun streamRoundTrip() {
        val key = ByteArray(32) { it.toByte() }
        for (size in listOf(0, 1, 65528, 65529, 300_000)) {
            val data = ByteArray(size) { (it * 7).toByte() }
            val out = ByteArrayOutputStream()
            SyncCrypto.sealStream(
                key,
                SyncCrypto.ad("blob", "x"),
                data.inputStream(),
                size.toLong(),
                out,
            )
            assertEquals(SyncCrypto.sealedSize(size.toLong()), out.size().toLong())
            val back = ByteArrayOutputStream()
            SyncCrypto.openStream(
                key,
                SyncCrypto.ad("blob", "x"),
                out.toByteArray().inputStream(),
                back,
            )
            assertArrayEquals(data, back.toByteArray())
        }
    }
}
