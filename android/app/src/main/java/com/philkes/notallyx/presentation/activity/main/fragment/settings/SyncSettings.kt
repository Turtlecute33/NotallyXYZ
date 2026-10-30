package com.philkes.notallyx.presentation.activity.main.fragment.settings

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.os.Build
import android.os.PersistableBundle
import android.text.format.DateUtils
import android.view.LayoutInflater
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
import com.philkes.notallyx.sync.SyncApi
import com.philkes.notallyx.sync.SyncManager
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

private fun Fragment.syncErrorText(code: String): String =
    when (code) {
        "invalid_url" -> getString(R.string.sync_error_invalid_url)
        "invalid_key" -> getString(R.string.sync_error_invalid_key)
        "unauthorized" -> getString(R.string.sync_error_unauthorized)
        "invalid_invite" -> getString(R.string.sync_error_invalid_invite)
        "signup_disabled" -> getString(R.string.sync_error_signup_disabled)
        "offline" -> getString(R.string.sync_error_offline)
        "rate_limited" -> getString(R.string.sync_error_rate_limited)
        "quota_exceeded" -> getString(R.string.sync_error_quota)
        "database_locked" -> getString(R.string.sync_error_locked)
        else -> code
    }

private fun Fragment.errorCode(e: Exception): String =
    when (e) {
        is SyncManager.SetupException -> e.message ?: "error"
        is SyncApi.HttpException ->
            when (e.code) {
                401 -> "unauthorized"
                429 -> "rate_limited"
                else -> e.error ?: "http_${e.code}"
            }
        is java.io.IOException -> "offline"
        else -> e.javaClass.simpleName
    }

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
    val dialog =
        MaterialAlertDialogBuilder(requireContext())
            .setTitle(if (create) R.string.sync_setup_create else R.string.sync_setup_connect)
            .setMessage(R.string.sync_setup_hint)
            .setView(layout.root)
            .setPositiveButton(R.string.sync_connect, null)
            .setCancelButton()
            .create()
    dialog.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    dialog.setOnShowListener {
        dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener { button ->
            val url = layout.ServerUrl.text.toString()
            val secret = layout.Secret.text.toString()
            button.isEnabled = false
            layout.Progress.show()
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
                } catch (e: Exception) {
                    layout.SecretLayout.error = syncErrorText(errorCode(e))
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
                        try {
                            sync.deleteServerData()
                        } catch (e: Exception) {
                            showToast(syncErrorText(errorCode(e)))
                        }
                    }
            }
        }
        .setCancelButton()
        .show()
}

private fun Fragment.confirm(message: Int, action: Int, block: suspend () -> Unit) {
    MaterialAlertDialogBuilder(requireContext())
        .setMessage(message)
        .setPositiveButton(action) { _, _ -> viewLifecycleOwner.lifecycleScope.launch { block() } }
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
            setTextIsSelectable(true)
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
 */
private fun Fragment.copySecret(text: String) {
    val clipboard = ContextCompat.getSystemService(requireContext(), ClipboardManager::class.java)
    val clip = ClipData.newPlainText(getString(R.string.sync_key), text)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        clip.description.extras =
            PersistableBundle().apply { putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true) }
    }
    clipboard?.setPrimaryClip(clip)
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) showToast(R.string.sync_key_copied)
}
