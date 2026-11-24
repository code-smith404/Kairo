/* D-Bus notification client used by tests/notifications.sh.
 *
 * Calls Notify on org.freedesktop.Notifications, verifies it gets a real id,
 * then closes the notification and waits for the NotificationClosed signal.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dbus/dbus.h>

static int send_notify(DBusConnection *conn, unsigned int *out_id) {
    DBusMessage *msg = dbus_message_new_method_call(
        "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications", "Notify");
    if (!msg) return 0;
    DBusMessageIter it;
    dbus_message_iter_init_append(msg, &it);
    const char *app = "kairo-test";
    const char *icon = "";
    const char *summary = "Kairo test notification";
    const char *body = "This is the body text of the toast.";
    const unsigned int replaces = 0;
    const int timeout = 1500;
    if (!dbus_message_iter_append_basic(&it, DBUS_TYPE_STRING, &app) ||
        !dbus_message_iter_append_basic(&it, DBUS_TYPE_UINT32, &replaces) ||
        !dbus_message_iter_append_basic(&it, DBUS_TYPE_STRING, &icon) ||
        !dbus_message_iter_append_basic(&it, DBUS_TYPE_STRING, &summary) ||
        !dbus_message_iter_append_basic(&it, DBUS_TYPE_STRING, &body))
        return 0;
    /* actions: "ok", "Do it" */
    DBusMessageIter actions;
    if (!dbus_message_iter_open_container(&it, DBUS_TYPE_ARRAY, "s", &actions))
        return 0;
    const char *key = "ok";
    const char *label = "Do it";
    if (!dbus_message_iter_append_basic(&actions, DBUS_TYPE_STRING, &key) ||
        !dbus_message_iter_append_basic(&actions, DBUS_TYPE_STRING, &label))
        return 0;
    if (!dbus_message_iter_close_container(&it, &actions)) return 0;
    /* hints: a{sv} with urgency = byte 2 (critical) */
    DBusMessageIter hints, entry, variant;
    if (!dbus_message_iter_open_container(&it, DBUS_TYPE_ARRAY, "{sv}", &hints))
        return 0;
    const char *hint_key = "urgency";
    if (!dbus_message_iter_open_container(&hints, DBUS_TYPE_DICT_ENTRY, NULL, &entry))
        return 0;
    if (!dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &hint_key))
        return 0;
    if (!dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, DBUS_TYPE_BYTE_AS_STRING, &variant))
        return 0;
    const unsigned char urgency = 2;
    if (!dbus_message_iter_append_basic(&variant, DBUS_TYPE_BYTE, &urgency))
        return 0;
    if (!dbus_message_iter_close_container(&entry, &variant)) return 0;
    if (!dbus_message_iter_close_container(&hints, &entry)) return 0;
    if (!dbus_message_iter_close_container(&it, &hints)) return 0;
    if (!dbus_message_iter_append_basic(&it, DBUS_TYPE_INT32, &timeout)) return 0;

    DBusError err;
    dbus_error_init(&err);
    DBusMessage *reply = dbus_connection_send_with_reply_and_block(conn, msg, 2000, &err);
    dbus_message_unref(msg);
    if (!reply) {
        fprintf(stderr, "notify failed: %s\n", err.message ? err.message : "?");
        dbus_error_free(&err);
        return 0;
    }
    dbus_message_get_args(reply, &err, DBUS_TYPE_UINT32, out_id, DBUS_TYPE_INVALID);
    dbus_message_unref(reply);
    if (dbus_error_is_set(&err)) {
        fprintf(stderr, "notify reply error: %s\n", err.message);
        dbus_error_free(&err);
        return 0;
    }
    return 1;
}

static void send_close(DBusConnection *conn, unsigned int id) {
    DBusMessage *msg = dbus_message_new_method_call(
        "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications", "CloseNotification");
    if (!msg) return;
    DBusMessageIter it;
    dbus_message_iter_init_append(msg, &it);
    dbus_message_iter_append_basic(&it, DBUS_TYPE_UINT32, &id);
    dbus_connection_send(conn, msg, NULL);
    dbus_connection_flush(conn);
    dbus_message_unref(msg);
}

int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "full";
    DBusError err;
    dbus_error_init(&err);
    DBusConnection *conn = dbus_bus_get(DBUS_BUS_SESSION, &err);
    if (!conn) {
        fprintf(stderr, "no session bus: %s\n", err.message);
        return 1;
    }

    /* GetServerInformation */
    DBusMessage *info = dbus_message_new_method_call(
        "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications", "GetServerInformation");
    DBusMessage *info_reply = dbus_connection_send_with_reply_and_block(conn, info, 2000, &err);
    dbus_message_unref(info);
    if (!info_reply) {
        fprintf(stderr, "GetServerInformation failed: %s\n", err.message);
        return 1;
    }
    char *name = NULL, *vendor = NULL, *version = NULL, *spec = NULL;
    dbus_message_get_args(info_reply, &err,
                          DBUS_TYPE_STRING, &name, DBUS_TYPE_STRING, &vendor,
                          DBUS_TYPE_STRING, &version, DBUS_TYPE_STRING, &spec,
                          DBUS_TYPE_INVALID);
    dbus_message_unref(info_reply);
    printf("server: %s %s %s spec=%s\n", name, vendor, version, spec);
    if (strcmp(name, "Kairo") != 0) {
        fprintf(stderr, "unexpected server name\n");
        return 1;
    }

    /* Match NotificationClosed signals before sending anything. */
    dbus_bus_add_match(conn, "type='signal',interface='org.freedesktop.Notifications'", &err);

    unsigned int id = 0;
    if (!send_notify(conn, &id)) return 1;
    printf("notify id=%u\n", id);
    if (id == 0) {
        fprintf(stderr, "daemon returned id 0\n");
        return 1;
    }

    if (strcmp(mode, "notify-only") == 0) return 0;

    send_close(conn, id);

    /* Wait for NotificationClosed with our id. */
    for (int i = 0; i < 100; i++) {
        dbus_connection_read_write_dispatch(conn, 100);
        DBusMessage *m = dbus_connection_pop_message(conn);
        if (!m) continue;
        if (dbus_message_is_signal(m, "org.freedesktop.Notifications", "NotificationClosed")) {
            unsigned int cid = 0, reason = 0;
            dbus_message_get_args(m, &err, DBUS_TYPE_UINT32, &cid,
                                  DBUS_TYPE_UINT32, &reason, DBUS_TYPE_INVALID);
            printf("closed id=%u reason=%u\n", cid, reason);
            if (cid == id && reason == 2) {
                printf("notification lifecycle ok\n");
                dbus_message_unref(m);
                return 0;
            }
        }
        dbus_message_unref(m);
    }
    fprintf(stderr, "did not receive NotificationClosed\n");
    return 1;
}
