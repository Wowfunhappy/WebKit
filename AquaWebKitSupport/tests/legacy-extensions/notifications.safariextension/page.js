for (const op of ['request', 'show', 'close']) document.getElementById(op).onclick = () => notificationProbe({ op, id: 'button' });
browser.runtime.onMessage.addListener(command => {
    if (command.target === notificationContext) return Promise.resolve(notificationProbe(command));
});
