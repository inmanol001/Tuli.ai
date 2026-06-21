#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_FILE="$ROOT_DIR/external_context.json"

mkdir -p "$ROOT_DIR"

osascript -l JavaScript <<'JXA' > "$OUT_FILE"
ObjC.import('Foundation')

function safeText(value) {
  if (value === undefined || value === null) return '';
  return String(value);
}

function toISO(value) {
  try {
    if (!value) return '';
    return new Date(value).toISOString();
  } catch (e) {
    return safeText(value);
  }
}

function collectMail(limit) {
  var out = [];
  try {
    var Mail = Application('Mail');
    Mail.includeStandardAdditions = true;
    var inbox = Mail.inbox();
    var msgs = inbox.messages().slice(0, limit);
    msgs.forEach(function (m) {
      out.push({
        date: toISO(m.dateReceived()),
        from: safeText(m.sender()),
        subject: safeText(m.subject()),
        read: !!m.readStatus()
      });
    });
  } catch (e) {
    out.push({ error: 'Mail: ' + safeText(e) });
  }
  return out;
}

function collectCalendar(limit) {
  var out = [];
  try {
    var Calendar = Application('Calendar');
    Calendar.includeStandardAdditions = true;
    var now = new Date();
    var end = new Date(now.getTime() + 24 * 60 * 60 * 1000);
    Calendar.calendars().forEach(function (cal) {
      try {
        cal.events().forEach(function (ev) {
          var start = ev.startDate();
          if (start && start >= now && start <= end) {
            out.push({
              date: toISO(start),
              title: safeText(ev.summary()),
              calendar: safeText(cal.name())
            });
          }
        });
      } catch (e) {}
    });
  } catch (e) {
    out.push({ error: 'Calendar: ' + safeText(e) });
  }
  return out.slice(0, limit);
}

function collectReminders(limit) {
  var out = [];
  try {
    var Reminders = Application('Reminders');
    Reminders.includeStandardAdditions = true;
    Reminders.lists().forEach(function (list) {
      try {
        list.reminders().forEach(function (rem) {
          if (!rem.completed()) {
            out.push({
              date: toISO(rem.dueDate()),
              title: safeText(rem.name()),
              list: safeText(list.name()),
              state: 'open'
            });
          }
        });
      } catch (e) {}
    });
  } catch (e) {
    out.push({ error: 'Reminders: ' + safeText(e) });
  }
  return out.slice(0, limit);
}

function activeAppName() {
  try {
    var se = Application('System Events');
    var app = se.applicationProcesses.whose({ frontmost: true })[0];
    return app ? safeText(app.name()) : '';
  } catch (e) {
    return '';
  }
}

var context = {
  generated_at: new Date().toISOString(),
  active_app: activeAppName(),
  mail: collectMail(8),
  calendar: collectCalendar(8),
  notes: collectReminders(8)
};

JSON.stringify(context, null, 2);
JXA
