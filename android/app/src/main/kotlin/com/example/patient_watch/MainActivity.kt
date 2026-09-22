package com.example.patient_watch

import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.patient_watch/image_compressor"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "getDeviceModel") {
                try {
                    val manufacturer = android.os.Build.MANUFACTURER
                    val model = android.os.Build.MODEL
                    val deviceName = if (model.lowercase().startsWith(manufacturer.lowercase())) {
                        model
                    } else {
                        val mfgCap = manufacturer.replaceFirstChar {
                            if (it.isLowerCase()) it.titlecase() else it.toString()
                        }
                        "$mfgCap $model"
                    }
                    result.success(deviceName)
                } catch (e: Exception) {
                    result.success("Android Phone")
                }
            } else if (call.method == "compressYuvToJpeg") {
                try {
                    val width = call.argument<Int>("width") ?: 0
                    val height = call.argument<Int>("height") ?: 0
                    val quality = call.argument<Int>("quality") ?: 70
                    val yBytes = call.argument<ByteArray>("y")
                    val uBytes = call.argument<ByteArray>("u")
                    val vBytes = call.argument<ByteArray>("v")
                    val yRowStride = call.argument<Int>("yRowStride") ?: width
                    val uvRowStride = call.argument<Int>("uvRowStride") ?: width
                    val uvPixelStride = call.argument<Int>("uvPixelStride") ?: 2

                    if (yBytes == null || width <= 0 || height <= 0) {
                        result.error("INVALID_ARGUMENT", "Invalid image parameters", null)
                        return@setMethodCallHandler
                    }

                    val nv21: ByteArray
                    if (uBytes == null || vBytes == null) {
                        // Already in NV21 format (single contiguous buffer)
                        nv21 = yBytes
                    } else {
                        // Convert YUV_420_888 3-plane buffer to NV21 format
                        val totalSize = width * height * 3 / 2
                        nv21 = ByteArray(totalSize)

                        // 1. Copy Y plane
                        var pos = 0
                        if (yRowStride == width) {
                            val copyLen = minOf(yBytes.size, width * height)
                            System.arraycopy(yBytes, 0, nv21, 0, copyLen)
                            pos = width * height
                        } else {
                            var yOffset = 0
                            for (row in 0 until height) {
                                if (yOffset + width <= yBytes.size && pos + width <= nv21.size) {
                                    System.arraycopy(yBytes, yOffset, nv21, pos, width)
                                }
                                yOffset += yRowStride
                                pos += width
                            }
                        }

                        // 2. Interleave V and U planes (NV21 expects V then U)
                        val uvHeight = height / 2
                        val uvWidth = width / 2
                        for (row in 0 until uvHeight) {
                            val uRowStart = row * uvRowStride
                            val vRowStart = row * uvRowStride
                            for (col in 0 until uvWidth) {
                                val uIndex = uRowStart + col * uvPixelStride
                                val vIndex = vRowStart + col * uvPixelStride
                                if (vIndex < vBytes.size && uIndex < uBytes.size && pos + 1 < nv21.size) {
                                    nv21[pos++] = vBytes[vIndex]
                                    nv21[pos++] = uBytes[uIndex]
                                }
                            }
                        }
                    }

                    val yuvImage = YuvImage(nv21, ImageFormat.NV21, width, height, null)
                    val out = ByteArrayOutputStream()
                    yuvImage.compressToJpeg(Rect(0, 0, width, height), quality, out)
                    result.success(out.toByteArray())
                } catch (e: Exception) {
                    result.error("COMPRESSION_ERROR", e.localizedMessage, null)
                }
            } else {
                result.notImplemented()
            }
        }
    }
}
