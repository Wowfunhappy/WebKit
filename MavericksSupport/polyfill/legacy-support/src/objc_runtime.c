/*
 * ObjC runtime functions added in 10.14+ / 11.0+ --
 * custom polyfill (not from macports-legacy-support).
 */

#include <objc/objc.h>
#include <objc/message.h>
#include <objc/runtime.h>

/* objc_alloc_init (added ~10.14.4) — combines [cls alloc] and [obj init] */
id objc_alloc_init(Class cls) {
	id obj = ((id(*)(Class, SEL))objc_msgSend)(cls, sel_getUid("alloc"));
	return ((id(*)(id, SEL))objc_msgSend)(obj, sel_getUid("init"));
}

/* objc_alloc (added ~10.14) — optimized [cls alloc] */
id objc_alloc(Class cls) {
	return ((id(*)(Class, SEL))objc_msgSend)(cls, sel_getUid("alloc"));
}

/* objc_opt_class (added macOS 11) — optimized [obj class] */
Class objc_opt_class(id obj) {
	if (!obj) return Nil;
	return ((Class(*)(id, SEL))objc_msgSend)(obj, sel_getUid("class"));
}

/* objc_opt_isKindOfClass (added macOS 11) */
BOOL objc_opt_isKindOfClass(id obj, Class cls) {
	if (!obj) return NO;
	return ((BOOL(*)(id, SEL, Class))objc_msgSend)(obj, sel_getUid("isKindOfClass:"), cls);
}

/* objc_opt_respondsToSelector (added macOS 11) */
BOOL objc_opt_respondsToSelector(id obj, SEL sel) {
	if (!obj) return NO;
	return ((BOOL(*)(id, SEL, SEL))objc_msgSend)(obj, sel_getUid("respondsToSelector:"), sel);
}

/* objc_unsafeClaimAutoreleasedReturnValue (added 10.11) */
extern id objc_retainAutoreleasedReturnValue(id obj);
id objc_unsafeClaimAutoreleasedReturnValue(id obj) {
	return objc_retainAutoreleasedReturnValue(obj);
}
