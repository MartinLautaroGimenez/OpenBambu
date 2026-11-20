package ar.openbambu.openbambu

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider
import java.io.File

/** Widget de pantalla de inicio: cámara, progreso, tiempo restante y pausa. */
class PrinterWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.printer_widget)

            views.setTextViewText(R.id.widget_title, widgetData.getString("title", "OpenBambu"))
            views.setTextViewText(R.id.widget_subtitle, widgetData.getString("subtitle", "Abrí la app para conectar"))

            val progress = widgetData.getInt("progress", -1)
            if (progress >= 0) {
                views.setViewVisibility(R.id.widget_progress, View.VISIBLE)
                views.setProgressBar(R.id.widget_progress, 100, progress, widgetData.getBoolean("indeterminate", false))
            } else {
                views.setViewVisibility(R.id.widget_progress, View.GONE)
            }

            val image = widgetData.getString("image", null)
            val bitmap = image?.let { loadBitmap(it) }
            if (bitmap != null) views.setImageViewBitmap(R.id.widget_camera, bitmap)

            // Botón pausar/reanudar solo durante una impresión
            val action = widgetData.getString("action", "")
            if (action == "pause" || action == "resume") {
                views.setViewVisibility(R.id.widget_toggle, View.VISIBLE)
                views.setImageViewResource(
                    R.id.widget_toggle,
                    if (action == "pause") R.drawable.ic_widget_pause else R.drawable.ic_widget_play,
                )
                views.setOnClickPendingIntent(
                    R.id.widget_toggle,
                    HomeWidgetBackgroundIntent.getBroadcast(context, Uri.parse("openbambu://$action")),
                )
            } else {
                views.setViewVisibility(R.id.widget_toggle, View.GONE)
            }

            views.setOnClickPendingIntent(
                R.id.widget_root,
                HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java),
            )
            appWidgetManager.updateAppWidget(id, views)
        }
    }

    private fun loadBitmap(path: String): Bitmap? {
        val file = File(path)
        if (!file.exists()) return null
        // Achicar: los widgets tienen un límite de memoria para imágenes
        val opts = BitmapFactory.Options().apply {
            inSampleSize = 3
            inPreferredConfig = Bitmap.Config.RGB_565
        }
        return try {
            BitmapFactory.decodeFile(path, opts)
        } catch (e: Exception) {
            null
        }
    }
}
