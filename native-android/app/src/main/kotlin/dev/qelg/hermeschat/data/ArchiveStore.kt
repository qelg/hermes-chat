package dev.qelg.hermeschat.data

import android.content.Context

internal class ArchiveStore(context: Context) {
    private val preferences =
        context.getSharedPreferences("session_archive", Context.MODE_PRIVATE)

    fun load(): Set<String> =
        preferences.getStringSet("archived_ids", emptySet()) ?: emptySet()

    fun archive(sessionId: String) {
        val ids = load() + sessionId
        preferences.edit().putStringSet("archived_ids", ids).apply()
    }

    fun unarchive(sessionId: String) {
        val ids = load() - sessionId
        preferences.edit().putStringSet("archived_ids", ids).apply()
    }

    fun isArchived(sessionId: String): Boolean =
        sessionId in load()
}