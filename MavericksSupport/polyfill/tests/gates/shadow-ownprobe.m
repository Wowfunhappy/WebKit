// Shadow gate probe.
// Does the class ITSELF define the selector? Nothing of the polyfill layer is linked in, so every
// method seen is the system's own. A leading '+' on the class name asks the metaclass.
#include <dlfcn.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int ownsSelector(Class cls, SEL sel)
{
    unsigned int n = 0;
    Method *methods = class_copyMethodList(cls, &n);
    if (!methods)
        return 0;
    int hit = 0;
    for (unsigned int i = 0; i < n; i++)
        if (method_getName(methods[i]) == sel) { hit = 1; break; }
    free(methods);
    return hit;
}
int main(int argc, char **argv)
{
    for (int i = 1; i < argc; i++)
        dlopen(argv[i], RTLD_LAZY | RTLD_LOCAL);
    char line[1024];
    while (fgets(line, sizeof line, stdin)) {
        line[strcspn(line, "\n")] = 0;
        char *className = strtok(line, "\t");
        char *pub = className ? strtok(NULL, "\t") : NULL;
        if (!pub)
            continue;
        int isMeta = className[0] == '+';
        Class cls = objc_getClass(isMeta ? className + 1 : className);
        if (!cls) {
            printf("%s\t%s\tNOCLASS\n", className, pub);
            continue;
        }
        Class where = isMeta ? object_getClass(cls) : cls;
        printf("%s\t%s\t%s\n", className, pub, ownsSelector(where, sel_getUid(pub)) ? "OWNS" : "not-own");
    }
    return 0;
}
