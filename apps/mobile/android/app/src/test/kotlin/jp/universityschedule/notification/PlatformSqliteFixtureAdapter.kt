package jp.universityschedule.notification

import android.database.Cursor
import android.database.sqlite.SQLiteDatabase

/** Robolectric-only fixture adapter. Production canonical code has no
 * android.database.sqlite dependency; this adapter is deliberately scoped to
 * src/test and only wraps isolated temporary files. */
internal fun SQLiteDatabase.asCanonicalFixture(): CanonicalSqliteDatabase =
    PlatformSqliteFixtureDatabase(this)

private class PlatformSqliteFixtureDatabase(
    private val database: SQLiteDatabase,
) : CanonicalSqliteDatabase {
    override fun rawQuery(sql: String, args: Array<String>?): CanonicalSqliteCursor =
        PlatformSqliteFixtureCursor(database.rawQuery(sql, args))

    override fun execSQL(sql: String, args: Array<Any?>?) {
        if (args == null) database.execSQL(sql) else database.execSQL(sql, args)
    }

    override fun delete(table: String, whereClause: String, whereArgs: Array<String>?): Int =
        database.delete(table, whereClause, whereArgs)

    override fun beginTransactionNonExclusive() = database.beginTransactionNonExclusive()
    override fun setTransactionSuccessful() = database.setTransactionSuccessful()
    override fun endTransaction() = database.endTransaction()
    override fun inTransaction(): Boolean = database.inTransaction()
    override fun close() = database.close()
}

private class PlatformSqliteFixtureCursor(
    private val cursor: Cursor,
) : CanonicalSqliteCursor {
    override fun moveToFirst(): Boolean = cursor.moveToFirst()
    override fun moveToNext(): Boolean = cursor.moveToNext()
    override fun getString(index: Int): String = cursor.getString(index)
    override fun getLong(index: Int): Long = cursor.getLong(index)
    override fun getDouble(index: Int): Double = cursor.getDouble(index)
    override fun getBlob(index: Int): ByteArray? = cursor.getBlob(index)
    override fun getInt(index: Int): Int = cursor.getInt(index)
    override fun isNull(index: Int): Boolean = cursor.isNull(index)
    override fun close() = cursor.close()
}
