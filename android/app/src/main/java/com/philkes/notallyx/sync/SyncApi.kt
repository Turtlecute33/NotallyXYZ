package com.philkes.notallyx.sync

import android.util.Base64
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URL
import org.json.JSONArray
import org.json.JSONObject

/** HTTP client for the NotallyXYZ sync server. All calls block; call them on Dispatchers.IO. */
class SyncApi(serverUrl: String, private val bearer: String) {

    private val base = serverUrl.trimEnd('/') + "/v1"

    class HttpException(val code: Int, val error: String?) :
        IOException("HTTP $code ${error ?: ""}")

    class RemoteChange(
        val kind: String,
        val id: String,
        val seq: Long,
        val deleted: Boolean,
        val data: ByteArray?,
    )

    class Page(val changes: List<RemoteChange>, val seq: Long, val more: Boolean)

    /** A deletion also carries [data]: the sealed tombstone (PROTOCOL.md, section 5). */
    class OutChange(
        val kind: String,
        val id: String,
        val base: Long,
        val data: ByteArray,
        val deleted: Boolean = false,
    )

    class Result(val kind: String, val id: String, val seq: Long, val conflict: Boolean)

    class BlobInfo(val id: String, val size: Long, val created: Long)

    fun createAccount(invite: String): Boolean =
        request("POST", "/account", JSONObject().put("invite", invite)).optBoolean("created")

    fun account(): JSONObject = request("GET", "/account")

    fun deleteAccount() {
        request("DELETE", "/account")
    }

    fun changes(since: Long, limit: Int = 200, wait: Int = 0): Page {
        val json =
            request(
                "GET",
                "/changes?since=$since&limit=$limit&wait=$wait",
                readTimeoutMs = (wait + 30) * 1000,
            )
        val array = json.getJSONArray("changes")
        val changes =
            (0 until array.length()).map { i ->
                val c = array.getJSONObject(i)
                RemoteChange(
                    c.getString("kind"),
                    c.getString("id"),
                    c.getLong("seq"),
                    c.optBoolean("deleted"),
                    c.optString("data")
                        .takeIf { it.isNotEmpty() }
                        ?.let { Base64.decode(it, Base64.DEFAULT) },
                )
            }
        return Page(changes, json.getLong("seq"), json.optBoolean("more"))
    }

    fun push(changes: List<OutChange>): List<Result> {
        val array = JSONArray()
        changes.forEach { c ->
            val o =
                JSONObject()
                    .put("kind", c.kind)
                    .put("id", c.id)
                    .put("base", c.base)
                    .put("data", Base64.encodeToString(c.data, Base64.NO_WRAP))
            if (c.deleted) o.put("deleted", true)
            array.put(o)
        }
        val results = request("POST", "/changes", JSONObject().put("changes", array))
        val out = results.getJSONArray("results")
        return (0 until out.length()).map { i ->
            val r = out.getJSONObject(i)
            Result(
                r.getString("kind"),
                r.getString("id"),
                r.getLong("seq"),
                r.optBoolean("conflict"),
            )
        }
    }

    fun missingBlobs(ids: Collection<String>): Set<String> {
        if (ids.isEmpty()) return emptySet()
        val json = request("POST", "/blobs/missing", JSONObject().put("ids", JSONArray(ids)))
        val array = json.getJSONArray("missing")
        return (0 until array.length()).map { array.getString(it) }.toSet()
    }

    fun listBlobs(): List<BlobInfo> {
        val array = request("GET", "/blobs").getJSONArray("blobs")
        return (0 until array.length()).map { i ->
            val b = array.getJSONObject(i)
            BlobInfo(b.getString("id"), b.getLong("size"), b.getLong("created"))
        }
    }

    fun putBlob(id: String, length: Long, write: (OutputStream) -> Unit) {
        val connection = open("PUT", "/blobs/$id", readTimeoutMs = 120_000)
        try {
            connection.doOutput = true
            connection.setFixedLengthStreamingMode(length)
            connection.setRequestProperty("Content-Type", "application/octet-stream")
            connection.outputStream.use(write)
            check(connection)
        } finally {
            connection.disconnect()
        }
    }

    /** Returns false if the blob does not exist on the server. */
    fun getBlob(id: String, read: (InputStream) -> Unit): Boolean {
        val connection = open("GET", "/blobs/$id", readTimeoutMs = 120_000)
        try {
            if (connection.responseCode == HttpURLConnection.HTTP_NOT_FOUND) return false
            check(connection)
            connection.inputStream.use(read)
            return true
        } finally {
            connection.disconnect()
        }
    }

    fun deleteBlob(id: String) {
        request("DELETE", "/blobs/$id")
    }

    private fun open(method: String, path: String, readTimeoutMs: Int): HttpURLConnection {
        val connection = URL(base + path).openConnection() as HttpURLConnection
        connection.requestMethod = method
        connection.connectTimeout = 15_000
        connection.readTimeout = readTimeoutMs
        connection.useCaches = false
        connection.instanceFollowRedirects = false
        connection.setRequestProperty("Authorization", "Bearer $bearer")
        connection.setRequestProperty("Accept", "application/json")
        return connection
    }

    private fun request(
        method: String,
        path: String,
        body: JSONObject? = null,
        readTimeoutMs: Int = 60_000,
    ): JSONObject {
        val connection = open(method, path, readTimeoutMs)
        try {
            if (body != null) {
                val bytes = body.toString().toByteArray()
                connection.doOutput = true
                connection.setFixedLengthStreamingMode(bytes.size)
                connection.setRequestProperty("Content-Type", "application/json")
                connection.outputStream.use { it.write(bytes) }
            }
            check(connection)
            if (connection.responseCode == HttpURLConnection.HTTP_NO_CONTENT) return JSONObject()
            val text = connection.inputStream.use { it.readLimited(32 shl 20).decodeToString() }
            return if (text.isBlank()) JSONObject() else JSONObject(text)
        } finally {
            connection.disconnect()
        }
    }

    private fun check(connection: HttpURLConnection) {
        val code = connection.responseCode
        if (code in 200..299) return
        val error =
            try {
                connection.errorStream
                    ?.use { JSONObject(it.readLimited(4096).decodeToString()) }
                    ?.optString("error")
            } catch (_: Exception) {
                null
            }
        throw HttpException(code, error)
    }

    /** A response larger than [max] bytes is an error, so that it cannot use all memory. */
    private fun InputStream.readLimited(max: Int): ByteArray {
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            val n = read(buffer)
            if (n < 0) return out.toByteArray()
            if (out.size() + n > max) throw IOException("Response too large")
            out.write(buffer, 0, n)
        }
    }

    companion object {
        /** Only HTTPS. Plain HTTP is accepted for a server on this device or the emulator host. */
        fun isAllowedUrl(url: String, allowLocalHttp: Boolean): Boolean {
            val parsed =
                try {
                    URL(url.trim())
                } catch (_: Exception) {
                    return false
                }
            if (parsed.host.isNullOrEmpty() || parsed.query != null || parsed.userInfo != null) {
                return false
            }
            return when (parsed.protocol) {
                "https" -> true
                "http" ->
                    allowLocalHttp && parsed.host in setOf("127.0.0.1", "localhost", "10.0.2.2")
                else -> false
            }
        }
    }
}
