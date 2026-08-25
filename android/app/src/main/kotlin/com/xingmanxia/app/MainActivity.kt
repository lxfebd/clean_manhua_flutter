package com.xingmanxia.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val notifChannelId = "xingmanxia_update"
    private val notifChannelIdHigh = "xingmanxia_install"
    private val notifId = 9527

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ensureChannel()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "xingmanxia/install")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("NO_PATH", "path is null", null)
                        } else {
                            try {
                                installApk(File(path))
                                result.success(true)
                            } catch (e: Exception) {
                                result.error("INSTALL_FAIL", e.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "xingmanxia/update_notification")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "showProgress" -> {
                        val title = call.argument<String>("title") ?: ""
                        val text = call.argument<String>("text") ?: ""
                        val received = call.argument<Int>("received") ?: 0
                        val total = call.argument<Int>("total") ?: 0
                        showProgressNotif(title, text, received, total)
                        result.success(true)
                    }
                    "showDone" -> {
                        val title = call.argument<String>("title") ?: ""
                        val text = call.argument<String>("text") ?: ""
                        val path = call.argument<String>("path") ?: ""
                        showDoneNotif(title, text, path)
                        result.success(true)
                    }
                    "showError" -> {
                        val title = call.argument<String>("title") ?: ""
                        val text = call.argument<String>("text") ?: ""
                        showErrorNotif(title, text)
                        result.success(true)
                    }
                    "showInstall" -> {
                        val path = call.argument<String>("path")
                        if (path != null) showInstallNotif(path)
                        result.success(true)
                    }
                    "cancel" -> {
                        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
                        nm.cancel(notifId)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun ensureChannel() {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (nm.getNotificationChannel(notifChannelId) == null) {
                val ch = NotificationChannel(
                    notifChannelId,
                    "更新下载",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "App 更新 APK 下载进度"
                    setShowBadge(false)
                }
                nm.createNotificationChannel(ch)
            }
            // 高优先级通道：用于下载完成后弹出安装器
            if (nm.getNotificationChannel(notifChannelIdHigh) == null) {
                val chHigh = NotificationChannel(
                    notifChannelIdHigh,
                    "安装更新",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "下载完成后拉起安装器"
                    setShowBadge(true)
                    enableVibration(true)
                    vibrationPattern = longArrayOf(0, 200, 200, 200)
                }
                nm.createNotificationChannel(chHigh)
            }
        }
    }

    private fun showProgressNotif(title: String, text: String, received: Int, total: Int) {
        val builder = NotificationCompat.Builder(this, notifChannelId)
            .setContentTitle(title)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)

        if (total > 0) {
            val pct = (received * 100 / total).coerceIn(0, 100)
            builder.setProgress(100, pct, false)
            val sb = StringBuilder()
            sb.append("$pct%  ${formatBytes(received)}/${formatBytes(total)}")
            if (text.isNotEmpty()) sb.append("  $text")
            builder.setContentText(sb.toString())
        } else {
            builder.setProgress(0, 0, true)
            builder.setContentText(if (text.isNotEmpty()) text else "下载中…")
        }

        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(notifId, builder.build())
    }

    private fun showDoneNotif(title: String, text: String, path: String) {
        val builder = NotificationCompat.Builder(this, notifChannelIdHigh)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setAutoCancel(true)
            .setOngoing(false)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_STATUS)

        if (path.isNotEmpty()) {
            val file = File(path)
            if (file.exists()) {
                val uri: Uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, "application/vnd.android.package-archive")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
                }
                val pi = PendingIntent.getActivity(
                    this, 0, intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                builder.setContentIntent(pi)
                // 全屏 Intent：屏幕开启时直接拉起安装器（Android 10+ 后台启动 Activity 的合规方式）
                builder.setFullScreenIntent(pi, true)
            }
        } else {
            val intent = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val pi = PendingIntent.getActivity(
                this, 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            builder.setContentIntent(pi)
        }

        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(notifId, builder.build())
    }

    private fun showErrorNotif(title: String, text: String) {
        val builder = NotificationCompat.Builder(this, notifChannelIdHigh)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_notify_error)
            .setAutoCancel(true)
            .setOngoing(false)
            .setPriority(NotificationCompat.PRIORITY_HIGH)

        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(notifId, builder.build())
    }

    private fun showInstallNotif(path: String) {
        val file = File(path)
        if (!file.exists()) return
        val uri: Uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val pi = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = NotificationCompat.Builder(this, notifChannelIdHigh)
            .setContentTitle("点击安装更新")
            .setContentText("下载完成，点击安装")
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setAutoCancel(true)
            .setOngoing(false)
            .setContentIntent(pi)
            .setFullScreenIntent(pi, true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(notifId, builder.build())
    }

    private fun formatBytes(bytes: Int): String {
        return when {
            bytes >= 1073741824 -> "%.2f GB".format(bytes / 1073741824.0)
            bytes >= 1048576 -> "%.1f MB".format(bytes / 1048576.0)
            bytes >= 1024 -> "%d KB".format(bytes / 1024)
            else -> "$bytes B"
        }
    }

    private fun installApk(file: File) {
        val uri: Uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        startActivity(intent)
    }
}
