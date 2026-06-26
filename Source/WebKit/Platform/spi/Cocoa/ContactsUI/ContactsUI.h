// MAVERICKS_BACKPORT: empty placeholder umbrella so `#import <ContactsUI/ContactsUI.h>` in ContactsUISPI.h resolves on 10.9, where the ContactsUI framework does not ship (the contact-picker SPI it would supply is unused/guarded out in the backport).
#pragma once
