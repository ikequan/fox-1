package ai.fox1.channels

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.CallLog
import android.provider.ContactsContract
import android.telecom.TelecomManager
import android.telephony.TelephonyManager
import ai.fox1.services.Fox1InCallService
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.text.SimpleDateFormat
import java.util.*

object PhoneChannel {
    private const val CHANNEL = "ai.fox1/phone"

    fun register(flutterEngine: FlutterEngine, context: Context) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "getContacts" -> {
                            val query = call.argument<String>("query") ?: ""
                            result.success(getContacts(context, query))
                        }
                        "getCallHistory" -> {
                            val limit = call.argument<Int>("limit") ?: 20
                            result.success(getCallHistory(context, limit))
                        }
                        "makeCall" -> {
                            val phoneNumber = call.argument<String>("phone_number") ?: ""
                            if (phoneNumber.isEmpty()) {
                                result.success(mapOf<String, Any>("success" to false, "error" to "No phone number"))
                                return@setMethodCallHandler
                            }
                            val intent = Intent(Intent.ACTION_CALL).apply {
                                data = Uri.parse("tel:$phoneNumber")
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            }
                            context.startActivity(intent)
                            result.success(mapOf<String, Any>("success" to true, "result" to "Calling $phoneNumber"))
                        }
                        "saveContact" -> {
                            val name = call.argument<String>("name") ?: ""
                            val phone = call.argument<String>("phone_number") ?: ""
                            if (name.isEmpty() || phone.isEmpty()) {
                                result.success(mapOf<String, Any>("success" to false, "error" to "Name and phone_number required"))
                                return@setMethodCallHandler
                            }
                            val contactId = saveContact(context, name, phone)
                            if (contactId != null) {
                                result.success(mapOf<String, Any>("success" to true, "contact_id" to contactId, "result" to "Contact '$name' saved"))
                            } else {
                                result.success(mapOf<String, Any>("success" to false, "error" to "Failed to save contact"))
                            }
                        }
                        "endCall" -> {
                            // Try InCallService first (cleanest approach)
                            var ended = Fox1InCallService.endActiveCall()
                            if (!ended) {
                                // Fallback: TelecomManager (API 28+) or reflection (API < 28)
                                ended = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                                    val tm = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
                                    tm.endCall()
                                } else {
                                    try {
                                        val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
                                        val method = Class.forName("android.telephony.TelephonyManager")
                                            .getMethod("endCall")
                                        method.invoke(tm) as? Boolean ?: false
                                    } catch (_: Exception) {
                                        false
                                    }
                                }
                            }
                            result.success(mapOf<String, Any>("success" to ended, "result" to if (ended) "Call ended" else "No active call"))
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: SecurityException) {
                    result.success(mapOf<String, Any>("success" to false, "error" to "Permission denied: ${e.message}"))
                } catch (e: Exception) {
                    result.success(mapOf<String, Any>("success" to false, "error" to (e.message ?: "Unknown error")))
                }
            }
    }

    private fun getContacts(context: Context, query: String): List<Map<String, String>> {
        val contacts = mutableListOf<Map<String, String>>()
        val uri = ContactsContract.CommonDataKinds.Phone.CONTENT_URI
        val projection = arrayOf(
            ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
            ContactsContract.CommonDataKinds.Phone.NUMBER
        )

        val selection = if (query.isNotEmpty()) {
            "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} LIKE ?"
        } else null

        val selectionArgs = if (query.isNotEmpty()) {
            arrayOf("%$query%")
        } else null

        val cursor = context.contentResolver.query(
            uri, projection, selection, selectionArgs,
            "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} ASC"
        )

        cursor?.use {
            val nameIdx = it.getColumnIndex(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME)
            val numberIdx = it.getColumnIndex(ContactsContract.CommonDataKinds.Phone.NUMBER)
            val seen = mutableSetOf<String>()
            while (it.moveToNext()) {
                val name = it.getString(nameIdx) ?: "Unknown"
                val number = it.getString(numberIdx) ?: continue
                // Deduplicate by name+number
                val key = "$name|$number"
                if (seen.add(key)) {
                    contacts.add(mapOf("name" to name, "phone_number" to number))
                }
            }
        }

        return contacts
    }

    private fun getCallHistory(context: Context, limit: Int): List<Map<String, Any?>> {
        val history = mutableListOf<Map<String, Any?>>()
        val dateFormat = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.getDefault())

        val cursor = context.contentResolver.query(
            CallLog.Calls.CONTENT_URI,
            arrayOf(
                CallLog.Calls.CACHED_NAME,
                CallLog.Calls.NUMBER,
                CallLog.Calls.TYPE,
                CallLog.Calls.DATE,
                CallLog.Calls.DURATION
            ),
            null, null,
            "${CallLog.Calls.DATE} DESC"
        )

        cursor?.use {
            val nameIdx = it.getColumnIndex(CallLog.Calls.CACHED_NAME)
            val numberIdx = it.getColumnIndex(CallLog.Calls.NUMBER)
            val typeIdx = it.getColumnIndex(CallLog.Calls.TYPE)
            val dateIdx = it.getColumnIndex(CallLog.Calls.DATE)
            val durationIdx = it.getColumnIndex(CallLog.Calls.DURATION)
            var count = 0

            while (it.moveToNext() && count < limit) {
                val typeInt = it.getInt(typeIdx)
                val typeStr = when (typeInt) {
                    CallLog.Calls.INCOMING_TYPE -> "incoming"
                    CallLog.Calls.OUTGOING_TYPE -> "outgoing"
                    CallLog.Calls.MISSED_TYPE -> "missed"
                    CallLog.Calls.REJECTED_TYPE -> "rejected"
                    else -> "unknown"
                }
                val dateMs = it.getLong(dateIdx)
                history.add(mapOf(
                    "name" to (it.getString(nameIdx) ?: "Unknown"),
                    "phone_number" to (it.getString(numberIdx) ?: ""),
                    "type" to typeStr,
                    "date" to dateFormat.format(Date(dateMs)),
                    // Raw epoch too: the formatted string is minute-precision,
                    // and matching "the call that just ended" needs better.
                    "date_ms" to dateMs,
                    "duration_seconds" to it.getLong(durationIdx)
                ))
                count++
            }
        }

        return history
    }

    private fun saveContact(context: Context, name: String, phone: String): String? {
        val ops = arrayListOf<android.content.ContentProviderOperation>()

        // Insert raw contact
        ops.add(
            android.content.ContentProviderOperation.newInsert(ContactsContract.RawContacts.CONTENT_URI)
                .withValue(ContactsContract.RawContacts.ACCOUNT_TYPE, null)
                .withValue(ContactsContract.RawContacts.ACCOUNT_NAME, null)
                .build()
        )

        // Name
        ops.add(
            android.content.ContentProviderOperation.newInsert(ContactsContract.Data.CONTENT_URI)
                .withValueBackReference(ContactsContract.Data.RAW_CONTACT_ID, 0)
                .withValue(ContactsContract.Data.MIMETYPE, ContactsContract.CommonDataKinds.StructuredName.CONTENT_ITEM_TYPE)
                .withValue(ContactsContract.CommonDataKinds.StructuredName.DISPLAY_NAME, name)
                .build()
        )

        // Phone number
        ops.add(
            android.content.ContentProviderOperation.newInsert(ContactsContract.Data.CONTENT_URI)
                .withValueBackReference(ContactsContract.Data.RAW_CONTACT_ID, 0)
                .withValue(ContactsContract.Data.MIMETYPE, ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE)
                .withValue(ContactsContract.CommonDataKinds.Phone.NUMBER, phone)
                .withValue(ContactsContract.CommonDataKinds.Phone.TYPE, ContactsContract.CommonDataKinds.Phone.TYPE_MOBILE)
                .build()
        )

        val results = context.contentResolver.applyBatch(ContactsContract.AUTHORITY, ops)
        return results.firstOrNull()?.uri?.lastPathSegment
    }
}
