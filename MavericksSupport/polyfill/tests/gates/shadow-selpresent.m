// Shadow gate probe.
// Does this machine's 10.9 already implement the public selector on that class? Ground truth: nothing
// of the polyfill layer is linked in, so every method seen here is the system's own.
#include <dlfcn.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// The class that DEFINES the selector, walking up from cls -- an inherited method is one a send of that
// selector would reach just the same, so it counts, but naming the owner is what makes a hit fixable.
// class_copyMethodList rather than class_getInstanceMethod: the latter consults
// +resolveInstanceMethod:, and a probe should not be able to make a class invent an answer.
static Class definingClass(Class cls, SEL sel)
{
    for (Class k = cls; k; k = class_getSuperclass(k)) {
        unsigned int n = 0;
        Method *methods = class_copyMethodList(k, &n);
        if (!methods)
            continue;
        int hit = 0;
        for (unsigned int i = 0; i < n; i++)
            if (method_getName(methods[i]) == sel) { hit = 1; break; }
        free(methods);
        if (hit)
            return k;
    }
    return NULL;
}

int main(int argc, char **argv)
{
    // The frameworks a class can come from, so that objc_getClass can see it. Each registry line also
    // names the image its class came from, and that one is loaded too.
    for (int i = 1; i < argc; i++)
        dlopen(argv[i], RTLD_LAZY | RTLD_LOCAL);

    char line[1024];
    while (fgets(line, sizeof line, stdin)) {
        line[strcspn(line, "\n")] = 0;
        if (!line[0])
            continue;
        char *className = strtok(line, "\t");
        char *side = className ? strtok(NULL, "\t") : NULL;
        char *pub = side ? strtok(NULL, "\t") : NULL;
        char *image = pub ? strtok(NULL, "\t") : NULL;
        if (!pub)
            continue;
        if (image && strcmp(image, "-"))
            dlopen(image, RTLD_LAZY | RTLD_LOCAL);

        Class cls = objc_getClass(className);
        if (!cls) {
            printf("%s\t%s\t%s\tNOCLASS\t-\n", className, side, pub);
            continue;
        }
        Class start = strcmp(side, "class") ? cls : object_getClass(cls);
        Class owner = definingClass(start, sel_getUid(pub));
        const char *ownerImage = owner ? class_getImageName(owner) : NULL;
        printf("%s\t%s\t%s\t%s\t%s\n", className, side, pub, owner ? "PRESENT" : "absent",
               owner ? (ownerImage ? ownerImage : class_getName(owner)) : "-");
    }
    return 0;
}
