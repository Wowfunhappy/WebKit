# Security Policy

## Reporting a Vulnerability

To privately report a security vulnerability, please send a message to the email address listed on mavericksforever.com. (I apologize for not listing this address directly, I'm trying to prevent bot spam. It should not be hard to find, I promise!)

### In scope:
- Any way that a web page open in Aqua WebKit could gain remote code execution on OS X 10.9.5 Mavericks, with Apple's final security update installed and the security patches available on mavericksforever.com, even if the actual exploit is inside an unrelated system library.
- Any way that one website could gain access to another website's secrets, including session tokens, saved passwords, etc.

### Out of scope:
- Attacks that require an already-compromised WebContent process.
- Attacks that require the user to have a malicious browser extension installed.
- Attacks that require the user to purposefully open a malicious file, or which require "Open safe files after downloading" to be enabled in Safari Preferences. (Aqua WebKit's installer automatically disables this setting.)
- General "hardening" unaccompanied by a clear, viable attack path.
- Vague concerns about Mavericks being insecure because it's old.

In some cases, "out of scope" items may still warrant opening an issue on Github, if the problem is realistically fixable on Mavericks. Thank you for your help!
