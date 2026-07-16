package dev.qelg.hermeschat.data

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

class SecureCredentials(context: Context) {
    private val prefs = EncryptedSharedPreferences.create(
        context,
        "hermes_credentials",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )
    fun load(): ConnectionConfig? {
        val url = prefs.getString("url", null) ?: return null
        return ConnectionConfig(url, prefs.getString("username", "").orEmpty(), prefs.getString("password", "").orEmpty(), prefs.getString("token", "").orEmpty())
    }
    fun save(config: ConnectionConfig) = prefs.edit()
        .putString("url", config.normalizedBaseUrl)
        .putString("username", config.username)
        .putString("password", config.password)
        .putString("token", config.token)
        .apply()
    fun clear() = prefs.edit().clear().apply()
}
