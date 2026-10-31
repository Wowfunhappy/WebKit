"use strict";
const notificationContext = location.pathname.split('/').pop().replace('.html', '');
const notificationRecords = [];
const notifications = new Map();
function notificationReport(event, data) {
    const record = { context: notificationContext, event, ...data };
    notificationRecords.push(record);
    fetch('http://127.0.0.1:8843/report?notification=' + encodeURIComponent(JSON.stringify(record)));
    const output = document.getElementById('results');
    if (output) output.textContent = JSON.stringify(notificationRecords, null, 2);
    return record;
}
function notificationProbe(command) {
    if (command.op === 'state')
        return notificationReport('state', { permission: Notification.permission, origin: location.origin, url: location.href, secure: isSecureContext });
    if (command.op === 'request')
        return Notification.requestPermission().then(result => notificationReport('request', { result, permission: Notification.permission }));
    if (command.op === 'show') {
        const item = new Notification('Aqua ' + notificationContext + ' ' + command.id, { body: 'Click to verify the notification event.', tag: command.id });
        notifications.set(command.id, item);
        for (const event of ['show', 'click', 'close', 'error'])
            item.addEventListener(event, () => notificationReport(event, { id: command.id, permission: Notification.permission }));
        return { created: command.id };
    }
    if (command.op === 'close') {
        notifications.get(command.id).close();
        return { closed: command.id };
    }
    if (command.op === 'records') return notificationRecords;
}
notificationProbe({ op: 'state' });
