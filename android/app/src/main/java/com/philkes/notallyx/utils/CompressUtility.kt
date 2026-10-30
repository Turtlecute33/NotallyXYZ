package com.philkes.notallyx.utils

import android.util.Log
import com.philkes.notallyx.data.model.Converters
import com.philkes.notallyx.data.model.SpanRepresentation
import java.io.ByteArrayOutputStream
import java.util.zip.Deflater
import java.util.zip.DeflaterOutputStream
import java.util.zip.InflaterInputStream
import org.json.JSONObject

/**
 * Compression utilities for large text payloads to decrease memory usage by leveraging Deflate to
 * de-/compress text + spans (JSON)
 */
object CompressUtility {

    private const val TAG = "CompressUtility"
    private const val TEXT_FIELD = "text"
    private const val SPANS_FIELD = "spans"

    // Threshold in characters for when to compress text (approximately 10KB)
    const val COMPRESSION_THRESHOLD: Int = 10_000

    /** Compresses text and spans using Deflate compression into a ByteArray. */
    fun compressTextAndSpans(text: String, spans: List<SpanRepresentation>): ByteArray {
        val jsonObject = JSONObject()
        jsonObject.put(TEXT_FIELD, text)
        jsonObject.put(SPANS_FIELD, Converters.spansToJSONArray(spans))
        val bytes = jsonObject.toString().toByteArray(Charsets.UTF_8)
        val output = ByteArrayOutputStream()
        val deflater = Deflater(Deflater.BEST_SPEED)
        try {
            DeflaterOutputStream(output, deflater).use { it.write(bytes) }
        } finally {
            // DeflaterOutputStream does not end a Deflater that it did not make
            deflater.end()
        }
        return output.toByteArray()
    }

    /** Decompresses text and spans that were compressed with Deflate. */
    fun decompressTextAndSpans(compressedData: ByteArray): Pair<String, List<SpanRepresentation>> {
        return try {
            val jsonString =
                InflaterInputStream(compressedData.inputStream()).use {
                    it.readBytes().toString(Charsets.UTF_8)
                }
            val jsonObject = JSONObject(jsonString)
            val text = jsonObject.getString(TEXT_FIELD)
            val spansArray = jsonObject.getJSONArray(SPANS_FIELD)
            val spans = Converters.jsonToSpans(spansArray)
            Pair(text, spans)
        } catch (e: Exception) {
            Log.e(TAG, "Invalid compressed data ($e), returning empty")
            Pair("", emptyList())
        }
    }
}
