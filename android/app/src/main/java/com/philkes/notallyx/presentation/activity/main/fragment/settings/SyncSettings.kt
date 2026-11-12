package com.philkes.notallyx.presentation.activity.main.fragment.settings

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.text.format.DateUtils
import android.view.LayoutInflater
import android.view.View
import android.view.WindowManager
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import androidx.core.content.ContextCompat
import androidx.fragment.app.Fragment
import androidx.lifecycle.lifecycleScope
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.philkes.notallyx.R
import com.philkes.notallyx.databinding.DialogSyncSetupBinding
import com.philkes.notallyx.databinding.PreferenceBinding
import com.philkes.notallyx.presentation.repeatOnLifecycleScope
import com.philkes.notallyx.presentation.setCancelButton
import com.philkes.notallyx.presentation.showToast
import com.philkes.notallyx.presentation.viewmodel.preference.NotallyXPreferences
import com.philkes.notallyx.sync.SyncManager
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/** The "Sync" row in Settings and its dialogs. */
fun Fragment.setupSync(binding: PreferenceBinding, preferences: NotallyXPreferences) {
    val sync = SyncManager.get(requireContext())
    binding.Title.setText(R.string.sync)
    viewLifecycleOwner.repeatOnLifecycleScope {
        combine(sync.state, preferences.syncLastSuccess.flow) { state, last -> state to last }
            .collect { (state, last) ->
                binding.Value.text =
                    when {
                        sync.keyUnreadable -> getString(R.string.sync_error_key_lost)
                        !sync.isEnabled -> getString(R.string.off)
                        state.running -> getString(R.string.sync_running)
                        state.error != null ->
                            getString(R.string.sync_failed, syncErrorText(state.error))
                        last == 0L -> getString(R.string.sync_never)
                        System.currentTimeMillis() - last < DateUtils.MINUTE_IN_MILLIS ->
                            getString(R.string.sync_just_now)
                        else ->
                            getString(
                                R.string.sync_last,
                                DateUtils.getRelativeTimeSpanString(last).toString(),
                            )
                    }
            }
    }
    binding.root.setOnClickListener {
        if (sync.isEnabled) showSyncActions(sync, preferences)
        else showSyncSetupChoice(sync, preferences)
    }
}

/** Text for a code of [SyncManager.errorCode]. */
private fun Fragment.syncErrorText(code: String): String =
    when (code) {
        "invalid_url" -> getString(R.string.sync_error_invalid_url)
        "invalid_key" -> getString(R.string.sync_error_invalid_key)
        "unauthorized" -> getString(R.string.sync_error_unauthorized)
        "invalid_invite" -> getString(R.string.sync_error_invalid_invite)
        "signup_disabled",
        "accounts_limit" -> getString(R.string.sync_error_signup_disabled)
        "offline" -> getString(R.string.sync_error_offline)
        "rate_limited" -> getString(R.string.sync_error_rate_limited)
        "quota_exceeded" -> getString(R.string.sync_error_quota)
        "database_locked" -> getString(R.string.sync_error_locked)
        "redirect" -> getString(R.string.sync_error_redirect)
        "unknown_host" -> getString(R.string.sync_error_unknown_host)
        "tls" -> getString(R.string.sync_error_tls)
        "bad_response" -> getString(R.string.sync_error_bad_response)
        "cursor_ahead" -> getString(R.string.sync_error_cursor_ahead)
        SyncManager.INCOMPLETE -> getString(R.string.sync_error_incomplete)
        else ->
            if (code.startsWith("http_")) {
                getString(R.string.sync_error_server, code.removePrefix("http_"))
            } else getString(R.string.unknown_error)
    }

private fun Fragment.syncErrorText(e: Exception) = syncErrorText(SyncManager.errorCode(e))

/** Errors that show on the server URL field, not on the key or invite field. */
private fun isUrlError(code: String) =
    code.startsWith("http_") ||
        code in setOf("invalid_url", "redirect", "unknown_host", "tls", "offline", "bad_response")

private fun Fragment.showSyncSetupChoice(sync: SyncManager, preferences: NotallyXPreferences) {
    val options =
        arrayOf(getString(R.string.sync_setup_create), getString(R.string.sync_setup_connect))
    MaterialAlertDialogBuilder(requireContext())
        .setTitle(R.string.sync)
        .setItems(options) { _, which -> showSyncSetup(sync, preferences, create = which == 0) }
        .setCancelButton()
        .show()
}

private fun Fragment.showSyncSetup(
    sync: SyncManager,
    preferences: NotallyXPreferences,
    create: Boolean,
) {
    val layout = DialogSyncSetupBinding.inflate(LayoutInflater.from(requireContext()))
    layout.ServerUrl.setText(preferences.syncServerUrl.value)
    layout.SecretLayout.hint = getString(if (create) R.string.sync_invite else R.string.sync_key)
    if (create && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        // The invite is no password of this app: do not offer to save it as the sync key.
        layout.Secret.importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
    }
    val dialog =
        MaterialAlertDialogBuilder(requireContext())
            .setTitle(if (create) R.string.sync_setup_create else R.string.sync_setup_connect)
            .setMessage(R.string.sync_setup_hint)
            .setView(layout.root)
            .setPositiveButton(if (create) R.string.sync_create else R.string.sync_connect, null)
            .setCancelButton()
            .create()
    dialog.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    dialog.setOnShowListener {
        dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener { button ->
            val url = layout.ServerUrl.text.toString()
            val secret = layout.Secret.text.toString()
            button.isEnabled = false
            layout.Progress.show()
            layout.ServerUrlLayout.error = null
            layout.SecretLayout.error = null
            viewLifecycleOwner.lifecycleScope.launch {
                try {
                    if (create) {
                        val key = sync.createAccount(url, secret)
                        dialog.dismiss()
                        showSyncKey(key)
                    } else {
                        sync.connect(url, secret)
                        dialog.dismiss()
                    }
                } catch (e: SyncManager.KeyNotSavedException) {
                    // The account exists: the user must get its key, also if sync did not start.
                    dialog.dismiss()
                    showSyncKey(e.key)
                    showToast(getString(R.string.sync_failed, syncErrorText(e)))
                } catch (e: Exception) {
                    val code = SyncManager.errorCode(e)
                    val field =
                        if (isUrlError(code)) layout.ServerUrlLayout else layout.SecretLayout
                    field.error = syncErrorText(code)
                    button.isEnabled = true
                    layout.Progress.hide()
                }
            }
        }
    }
    dialog.show()
}

private fun Fragment.showSyncActions(sync: SyncManager, preferences: NotallyXPreferences) {
    val options =
        arrayOf(
            getString(R.string.sync_now),
            getString(R.string.sync_show_key),
            getString(R.string.sync_disconnect),
            getString(R.string.sync_delete_server),
        )
    MaterialAlertDialogBuilder(requireContext())
        .setTitle(preferences.syncServerUrl.value)
        .setItems(options) { _, which ->
            when (which) {
                0 -> sync.requestSync()
                1 -> showSyncKey(preferences.syncKey.value)
                2 ->
                    confirm(R.string.sync_disconnect_message, R.string.sync_disconnect) {
                        sync.disconnect()
                    }
                3 ->
                    confirm(R.string.sync_delete_server_message, R.string.delete) {
                        sync.deleteServerData()
                    }
            }
        }
        .setCancelButton()
        .show()
}

private fun Fragment.confirm(message: Int, action: Int, block: suspend () -> Unit) {
    MaterialAlertDialogBuilder(requireContext())
        .setMessage(message)
        .setPositiveButton(action) { _, _ ->
            viewLifecycleOwner.lifecycleScope.launch {
                try {
                    block()
                } catch (e: Exception) {
                    if (e !is CancellationException) showToast(syncErrorText(e))
                }
            }
        }
        .setCancelButton()
        .show()
}

private fun Fragment.showToast(text: String) = context?.showToast(text)

private fun Fragment.showSyncKey(key: String) {
    val view =
        TextView(requireContext()).apply {
            text = key
            typeface = android.graphics.Typeface.MONOSPACE
            textSize = 18f
            val padding = (24 * resources.displayMetrics.density).toInt()
            setPadding(padding, padding / 2, padding, 0)
        }
    val dialog =
        MaterialAlertDialogBuilder(requireContext())
            .setTitle(R.string.sync_key_title)
            .setMessage(R.string.sync_key_message)
            .setView(view)
            .setPositiveButton(android.R.string.ok, null)
            .setNeutralButton(R.string.copy) { _, _ -> copySecret(key) }
            .setCancelable(false)
            .create()
    dialog.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    dialog.show()
}

/**
 * Copies the key and marks it as sensitive, so that Android 13+ hides it in the clipboard preview.
 * After a minute the clipboard is cleared, unless it holds something else then.
 */
private fun Fragment.copySecret(text: String) {
    val clipboard =
        ContextCompat.getSystemService(requireContext(), ClipboardManager::class.java) ?: return
    val clip = ClipData.newPlainText(getString(R.string.sync_key), text)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        clip.description.extras =
            PersistableBundle().apply { putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true) }
    }
    clipboard.setPrimaryClip(clip)
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) showToast(R.string.sync_key_copied)
    Handler(Looper.getMainLooper()).postDelayed({ clearSecret(clipboard, text) }, 60_000L)
}

/**
 * Clears the clipboard if it still holds [text]. Android 10+ does not let an app in the background
 * read the clipboard: then it is cleared too, as it can still hold the key.
 */
private fun clearSecret(clipboard: ClipboardManager, text: String) {
    try {
        val clip = clipboard.primaryClip
        if (clip != null && (clip.itemCount == 0 || clip.getItemAt(0).text?.toString() != text)) {
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) clipboard.clearPrimaryClip()
        else clipboard.setPrimaryClip(ClipData.newPlainText("", ""))
    } catch (_: Exception) {}
}
