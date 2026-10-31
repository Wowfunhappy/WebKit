window.addEventListener('notification-command', event => {
    const command = JSON.parse(event.detail);
    const reply = result => window.dispatchEvent(new CustomEvent('notification-reply', { detail: JSON.stringify(result) }));
    if (command.target === 'content') {
        if (command.op === 'show') {
            const item = new Notification('Content script permission test');
            for (const event of ['show', 'error'])
                item.addEventListener(event, () => reply({ event, permission: Notification.permission, origin: location.origin }));
        } else
            reply({ permission: Notification.permission, origin: location.origin });
        return;
    }
    browser.runtime.sendMessage(command).then(reply);
});
