// A class object's class is its metaclass, which is what the modern runtime reports here.
#include "wk_polyfill.h"

#include <objc/runtime.h>

WK_POLYFILL_ABSENT("/usr/lib/libobjc.A.dylib", BOOL, object_isClass, (id obj))
{
    return obj && class_isMetaClass(object_getClass(obj));
}
