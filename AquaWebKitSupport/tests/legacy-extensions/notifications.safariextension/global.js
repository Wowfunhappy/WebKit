browser.runtime.onMessage.addListener(command => {
    if (command.target === 'global') return Promise.resolve(notificationProbe(command));
});
