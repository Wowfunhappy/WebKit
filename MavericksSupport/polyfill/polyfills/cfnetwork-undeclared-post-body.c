// MAVERICKS_BACKPORT: a POST body whose media type the sender does not know goes out with no
// Content-Type field, which is what modern CFNetwork does, what the Fetch specification asks for (a
// BufferSource body contributes no type, so FetchBody::extract sets none), and what a working
// reference browser on this host sends to a licence endpoint that rejects the alternative. 10.9's
// CFNetwork instead announces such a body as application/x-www-form-urlencoded, so a server that
// parses the body as form data receives one that is not.
//
// The field is synthesised in HTTPProtocol::_createMutableCanonicalRequest, below every request
// object: it is absent from originalRequest, from currentRequest, and from currentRequest after the
// load starts, and appears only on the wire. So there is no request for WebCore or a method
// replacement to correct, and no API expresses it either -- every body-carrying shape on 10.9
// (HTTPBody, HTTPBodyStream, uploadTaskWithRequest:fromData:, uploadTaskWithStreamedRequest: whose
// request carries no body at all, and setting then deleting the field) is stamped identically,
// CFNetwork exports no property or key that suppresses it, and the canonicaliser consults none.
//
// What it does is three instructions:
//
//     movq  _kCFHTTPHeaderContentType(%rip), %rsi           ; field name
//     movq  _kCFHTTPProtocolDefaultFormMimeType(%rip), %rdx ; value
//     callq _CFURLRequestSetHTTPHeaderFieldValue
//
// and that setter, measured here, *removes* the field when the value is NULL. Clearing the constant
// therefore makes CFNetwork's own code delete Content-Type where it would otherwise invent one. No
// value is substituted: the result is the field's absence, which is the behaviour being restored.
// A declared type is untouched, because the canonicaliser only reaches these instructions when the
// field is absent.
//
// The constant is non-external, so nothing links to it and no interposition reaches the call, which
// is direct and intra-image. It is a named entry in CFNetwork's symbol table, and it is found by
// that name -- never a fixed offset or a byte pattern -- and cleared only once the value it holds
// has been confirmed to be the media type in question, so a CFNetwork this does not describe keeps
// whatever it has.
//
// THIS HACK WAS EXPLICITLY APPROVED BY THE MAINTAINER AS AN EXCEPTION TO OUR STANDARD POLICY.
// DO NOT COPY THIS PATTERN ELSEWHERE IN THE CODEBASE, OR REMOVE THIS HACK WITHOUT EXPLICIT APPROVAL.
//

#include <stdio.h>
#include <stdlib.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <stdbool.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static const char kSymbolName[] = "_kCFHTTPProtocolDefaultFormMimeType";
static const char kFormMediaType[] = "application/x-www-form-urlencoded";
static const char kCFNetworkSuffix[] = "/CFNetwork.framework/Versions/A/CFNetwork";

static void __attribute__((noreturn)) fail(const char *reason)
{
    fprintf(stderr, "[wk_polyfill] FATAL: cfnetwork-undeclared-post-body: %s.\n", reason);
    fflush(stderr);
    abort();
}

// The network process is the only one whose HTTP requests are all WebKit's, so it is the only one
// this runs in. A host application loading WebKit keeps the CFNetwork it had for its own traffic.
static bool isWebKitNetworkProcess(void)
{
    const char *name = getprogname();
    return name && !strcmp(name, "com.apple.WebKit.Networking");
}

// The runtime address of |name| in the image at |index|, from that image's own symbol table.
static void *symbolAddress(uint32_t index, const char *name)
{
    const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(index);
    if (!header || header->magic != MH_MAGIC_64)
        return NULL;

    const struct load_command *command = (const struct load_command *)(header + 1);
    const struct symtab_command *symtab = NULL;
    uint64_t linkeditVMAddress = 0, linkeditFileOffset = 0;
    bool foundLinkedit = false;

    for (uint32_t i = 0; i < header->ncmds; ++i) {
        if (command->cmd == LC_SYMTAB)
            symtab = (const struct symtab_command *)command;
        else if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
            if (!strcmp(segment->segname, SEG_LINKEDIT)) {
                linkeditVMAddress = segment->vmaddr;
                linkeditFileOffset = segment->fileoff;
                foundLinkedit = true;
            }
        }
        command = (const struct load_command *)((const uint8_t *)command + command->cmdsize);
    }
    if (!symtab || !foundLinkedit)
        return NULL;

    intptr_t slide = _dyld_get_image_vmaddr_slide(index);
    const uint8_t *linkedit = (const uint8_t *)(uintptr_t)(linkeditVMAddress + slide - linkeditFileOffset);
    const struct nlist_64 *symbols = (const struct nlist_64 *)(linkedit + symtab->symoff);
    const char *strings = (const char *)(linkedit + symtab->stroff);

    for (uint32_t i = 0; i < symtab->nsyms; ++i) {
        if (!symbols[i].n_un.n_strx || (symbols[i].n_type & N_TYPE) != N_SECT)
            continue;
        if (strcmp(strings + symbols[i].n_un.n_strx, name))
            continue;
        return (void *)(uintptr_t)(symbols[i].n_value + slide);
    }
    return NULL;
}

// The constant is a compiler-built CFString: { isa, flags, const char *bytes, length }. Reading it
// that way keeps this constructor free of CoreFoundation, which a dyld initializer cannot assume is
// initialised yet -- a CF call here answers for the state of CF, not for the state of the constant.
struct constantCFString {
    const void *isa;
    unsigned long flags;
    const char *bytes;
    unsigned long length;
};

__attribute__((constructor)) static void clearDefaultFormMediaType(void)
{
    if (!isWebKitNetworkProcess())
        return;

    for (uint32_t i = 0, count = _dyld_image_count(); i < count; ++i) {
        const char *path = _dyld_get_image_name(i);
        if (!path)
            continue;
        size_t length = strlen(path), suffixLength = strlen(kCFNetworkSuffix);
        if (length < suffixLength || strcmp(path + length - suffixLength, kCFNetworkSuffix))
            continue;

        // Each check below describes the CFNetwork this is written against. A process that reaches
        // one and fails it would go on announcing a body type the sender never chose, on every
        // undeclared POST, with nothing said -- so each is fatal, and names itself on the way out.
        struct constantCFString **slot = (struct constantCFString **)symbolAddress(i, kSymbolName);
        if (!slot)
            fail("CFNetwork's symbol table has no kCFHTTPProtocolDefaultFormMimeType");

        // The polyfill archive is linked into WebCore, WebKit, WebKit2 and JavaScriptCore, which
        // share this process, so this initializer runs once per framework. A slot already cleared is
        // this work already done by the first of them, not a CFNetwork that fails the description.
        struct constantCFString *value = *slot;
        if (!value)
            return;
        if (!value->bytes)
            fail("the constant holds no inline bytes, so it is not the CFString this describes");
        if (value->length != strlen(kFormMediaType) || strcmp(value->bytes, kFormMediaType))
            fail("the constant does not hold the form media type this describes");

        long pageSize = sysconf(_SC_PAGESIZE);
        if (pageSize <= 0)
            fail("sysconf(_SC_PAGESIZE) gave no page size to align the write to");

        // The constant lives in __DATA, which this CFNetwork ships read-write (initprot 0x3; there
        // is no __DATA_CONST here). mprotect only spans the write, which can straddle two pages,
        // and leaves the protection the segment came with -- the same page carries the rest of
        // CFNetwork's CFString constants.
        uintptr_t page = (uintptr_t)slot & ~(uintptr_t)(pageSize - 1);
        size_t span = ((uintptr_t)slot + sizeof(*slot) > page + (uintptr_t)pageSize)
            ? (size_t)pageSize * 2 : (size_t)pageSize;
        if (mprotect((void *)page, span, PROT_READ | PROT_WRITE))
            fail("the page holding the constant could not be made writable");
        *slot = NULL;
        return;
    }

    // Reaching here is the network process running without the CFNetwork every request in it goes
    // through, which the checks above exist to rule out.
    fail("the network process has no CFNetwork loaded");
}
