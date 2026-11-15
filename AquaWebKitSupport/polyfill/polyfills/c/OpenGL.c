// OpenGL: libGL entry points whose driver implementations deviate from the GL specification.
// ANGLE's OpenGL backend resolves every GL function with dlsym on this libGL.dylib handle.
#include "wk_polyfill.h"

#include <OpenGL/gl3.h>
#include <string.h>

#define WK_LIBGL "/System/Library/Frameworks/OpenGL.framework/Libraries/libGL.dylib"

WK_SYSTEM_FN(WK_LIBGL, const GLubyte *, glGetString, (GLenum));
WK_SYSTEM_FN(WK_LIBGL, GLboolean, glIsEnabled, (GLenum));
WK_SYSTEM_FN(WK_LIBGL, void, glEnable, (GLenum));
WK_SYSTEM_FN(WK_LIBGL, void, glDisable, (GLenum));
WK_SYSTEM_FN(WK_LIBGL, void, glGetIntegerv, (GLenum, GLint *));
WK_SYSTEM_FN(WK_LIBGL, void, glBindFramebuffer, (GLenum, GLuint));
WK_SYSTEM_FN(WK_LIBGL, GLenum, glCheckFramebufferStatus, (GLenum));
WK_SYSTEM_FN(WK_LIBGL, void, glGetFramebufferAttachmentParameteriv, (GLenum, GLenum, GLenum, GLint *));
WK_SYSTEM_FN(WK_LIBGL, void, glGetVertexAttribiv, (GLuint, GLenum, GLint *));
WK_SYSTEM_FN(WK_LIBGL, void, glEnableVertexAttribArray, (GLuint));
WK_SYSTEM_FN(WK_LIBGL, void, glDisableVertexAttribArray, (GLuint));

// The current context's GL_VENDOR or GL_RENDERER string. Each context answers for its own renderer,
// and one process can hold contexts on several, so it is read per call. NULL without a context.
static const char *wk_currentContextString(GLenum name)
{
    return (const char *)WK_SYSTEM(glGetString)(name);
}

// --- glBlitFramebuffer --------------------------------------------------------------------------
//
// NVIDIA's driver (GeForceGLDriver, measured with the 334.01.03f11 web driver on GK110) performs a
// depth or stencil blit by drawing through a temporary color target that aliases the depth buffer.
// With GL_FRAMEBUFFER_SRGB enabled and a float color attachment (RGBA16F, RG16F, RGBA32F), the
// neutral-state helper it runs before that draw re-sends the application framebuffer's render-target
// formats over the temporary target's. The blit completes, and the next color write to that
// framebuffer faults the GPU channel (GR Error 5 or MMU Error 2), which aborts the process.
//
// GL_FRAMEBUFFER_SRGB affects only color buffers with sRGB encoding, and default-framebuffer color
// buffers. A depth or stencil blit on NVIDIA with sRGB writes enabled is therefore issued as:
//  - one call with sRGB writes disabled, when no such color buffer takes part;
//  - otherwise, a color blit under the caller's sRGB state followed by a depth/stencil blit with sRGB
//    writes disabled, provided each half is valid on its own (GL 4.1 §4.3.2). A call that fails
//    those checks, or uses a filter other than GL_NEAREST or bits outside the three buffer bits,
//    reaches the driver unchanged and raises its own error.
typedef void (*wk_blitFramebufferFunction)(GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLint,
                                           GLbitfield, GLenum);

struct wk_attachmentFormat {
    GLint objectType;
    GLint componentType;
    GLint colorEncoding;
    GLint sizes[6];
};

// Queries the framebuffer bound to GL_DRAW_FRAMEBUFFER. 10.9's Apple Software Renderer answers
// GL_FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE for the draw framebuffer when the target is
// GL_READ_FRAMEBUFFER.
static void wk_queryAttachmentFormat(GLenum attachment, struct wk_attachmentFormat *format)
{
    static const GLenum sizeNames[6] = {
        GL_FRAMEBUFFER_ATTACHMENT_RED_SIZE, GL_FRAMEBUFFER_ATTACHMENT_GREEN_SIZE,
        GL_FRAMEBUFFER_ATTACHMENT_BLUE_SIZE, GL_FRAMEBUFFER_ATTACHMENT_ALPHA_SIZE,
        GL_FRAMEBUFFER_ATTACHMENT_DEPTH_SIZE, GL_FRAMEBUFFER_ATTACHMENT_STENCIL_SIZE,
    };
    memset(format, 0, sizeof *format);
    WK_SYSTEM(glGetFramebufferAttachmentParameteriv)(GL_DRAW_FRAMEBUFFER, attachment,
        GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &format->objectType);
    if (format->objectType == GL_NONE)
        return;
    WK_SYSTEM(glGetFramebufferAttachmentParameteriv)(GL_DRAW_FRAMEBUFFER, attachment,
        GL_FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE, &format->componentType);
    WK_SYSTEM(glGetFramebufferAttachmentParameteriv)(GL_DRAW_FRAMEBUFFER, attachment,
        GL_FRAMEBUFFER_ATTACHMENT_COLOR_ENCODING, &format->colorEncoding);
    for (int i = 0; i < 6; i++)
        WK_SYSTEM(glGetFramebufferAttachmentParameteriv)(GL_DRAW_FRAMEBUFFER, attachment, sizeNames[i], &format->sizes[i]);
}

static int wk_sameFormat(const struct wk_attachmentFormat *a, const struct wk_attachmentFormat *b)
{
    return a->componentType == b->componentType && a->colorEncoding == b->colorEncoding
        && !memcmp(a->sizes, b->sizes, sizeof a->sizes);
}

// Fixed-point and floating-point color buffers blit into each other; signed and unsigned integer
// buffers blit only within their own class.
static GLint wk_colorClass(GLint componentType)
{
    return componentType == GL_INT || componentType == GL_UNSIGNED_INT ? componentType : GL_FLOAT;
}

// The attachment standing for every color buffer a read or draw buffer selects (a default
// framebuffer's color buffers share one format), or 0 for a value not mapped here.
static GLenum wk_colorAttachment(GLuint framebuffer, GLint buffer)
{
    if (framebuffer)
        return buffer >= GL_COLOR_ATTACHMENT0 && buffer <= GL_COLOR_ATTACHMENT15 ? (GLenum)buffer : 0;
    switch (buffer) {
    case GL_FRONT:
    case GL_LEFT:
    case GL_FRONT_LEFT:
        return GL_FRONT_LEFT;
    case GL_BACK:
    case GL_BACK_LEFT:
        return GL_BACK_LEFT;
    case GL_RIGHT:
    case GL_FRONT_RIGHT:
        return GL_FRONT_RIGHT;
    case GL_BACK_RIGHT:
        return GL_BACK_RIGHT;
    default:
        return 0;
    }
}

enum { wk_maxBlitDrawBuffers = 16 };

// The buffers a blit reads and writes. Index 0 of depth and stencil is the read framebuffer's,
// index 1 the draw framebuffer's.
struct wk_blitBuffers {
    GLuint readFramebuffer;
    GLuint drawFramebuffer;
    int unresolved;
    int complete;
    int readMultisampled;
    struct wk_attachmentFormat readColor;
    int drawColorCount;
    struct wk_attachmentFormat drawColor[wk_maxBlitDrawBuffers];
    struct wk_attachmentFormat depth[2];
    struct wk_attachmentFormat stencil[2];
};

static void wk_queryBlitBuffers(struct wk_blitBuffers *buffers)
{
    memset(buffers, 0, sizeof *buffers);
    GLint readFramebuffer = 0, drawFramebuffer = 0, readBuffer = GL_NONE;
    WK_SYSTEM(glGetIntegerv)(GL_READ_FRAMEBUFFER_BINDING, &readFramebuffer);
    WK_SYSTEM(glGetIntegerv)(GL_DRAW_FRAMEBUFFER_BINDING, &drawFramebuffer);
    WK_SYSTEM(glGetIntegerv)(GL_READ_BUFFER, &readBuffer);
    buffers->readFramebuffer = (GLuint)readFramebuffer;
    buffers->drawFramebuffer = (GLuint)drawFramebuffer;

    buffers->complete = WK_SYSTEM(glCheckFramebufferStatus)(GL_DRAW_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
    GLint maxDrawBuffers = 0;
    WK_SYSTEM(glGetIntegerv)(GL_MAX_DRAW_BUFFERS, &maxDrawBuffers);
    if (maxDrawBuffers > wk_maxBlitDrawBuffers)
        maxDrawBuffers = wk_maxBlitDrawBuffers;
    for (GLint i = 0; i < maxDrawBuffers; i++) {
        GLint buffer = GL_NONE;
        WK_SYSTEM(glGetIntegerv)(GL_DRAW_BUFFER0 + i, &buffer);
        if (buffer == GL_NONE)
            continue;
        GLenum attachment = wk_colorAttachment(buffers->drawFramebuffer, buffer);
        if (attachment)
            wk_queryAttachmentFormat(attachment, &buffers->drawColor[buffers->drawColorCount++]);
        else
            buffers->unresolved = 1;
    }
    wk_queryAttachmentFormat(drawFramebuffer ? GL_DEPTH_ATTACHMENT : GL_DEPTH, &buffers->depth[1]);
    wk_queryAttachmentFormat(drawFramebuffer ? GL_STENCIL_ATTACHMENT : GL_STENCIL, &buffers->stencil[1]);

    // The read framebuffer's formats, completeness and GL_SAMPLE_BUFFERS are read with it bound as
    // the draw framebuffer.
    if (readFramebuffer != drawFramebuffer)
        WK_SYSTEM(glBindFramebuffer)(GL_DRAW_FRAMEBUFFER, buffers->readFramebuffer);
    if (WK_SYSTEM(glCheckFramebufferStatus)(GL_DRAW_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE) {
        GLint sampleBuffers = 0;
        WK_SYSTEM(glGetIntegerv)(GL_SAMPLE_BUFFERS, &sampleBuffers);
        buffers->readMultisampled = sampleBuffers > 0;
    } else
        buffers->complete = 0;
    if (readBuffer != GL_NONE) {
        GLenum attachment = wk_colorAttachment(buffers->readFramebuffer, readBuffer);
        if (attachment)
            wk_queryAttachmentFormat(attachment, &buffers->readColor);
        else
            buffers->unresolved = 1;
    }
    wk_queryAttachmentFormat(readFramebuffer ? GL_DEPTH_ATTACHMENT : GL_DEPTH, &buffers->depth[0]);
    wk_queryAttachmentFormat(readFramebuffer ? GL_STENCIL_ATTACHMENT : GL_STENCIL, &buffers->stencil[0]);
    if (readFramebuffer != drawFramebuffer)
        WK_SYSTEM(glBindFramebuffer)(GL_DRAW_FRAMEBUFFER, buffers->drawFramebuffer);
}

// Whether GL_FRAMEBUFFER_SRGB can change what the color part of the blit writes.
static int wk_srgbAffectsBlitColor(const struct wk_blitBuffers *buffers)
{
    if (!buffers->readFramebuffer || !buffers->drawFramebuffer || buffers->unresolved)
        return 1;
    if (buffers->readColor.objectType != GL_NONE && buffers->readColor.colorEncoding == GL_SRGB)
        return 1;
    for (int i = 0; i < buffers->drawColorCount; i++) {
        if (buffers->drawColor[i].objectType != GL_NONE && buffers->drawColor[i].colorEncoding == GL_SRGB)
            return 1;
    }
    return 0;
}

// Whether the color blit and the depth/stencil blit are each valid on their own. Only the per-buffer
// errors of GL 4.1 §4.3.2 are checked; every other error applies to both halves alike.
static int wk_blitHalvesValidSeparately(const struct wk_blitBuffers *buffers, GLbitfield mask)
{
    if (buffers->unresolved || !buffers->complete)
        return 0;

    if (buffers->readColor.objectType != GL_NONE) {
        for (int i = 0; i < buffers->drawColorCount; i++) {
            const struct wk_attachmentFormat *draw = &buffers->drawColor[i];
            if (draw->objectType == GL_NONE)
                continue;
            if (wk_colorClass(draw->componentType) != wk_colorClass(buffers->readColor.componentType))
                return 0;
            if (buffers->readMultisampled && !wk_sameFormat(draw, &buffers->readColor))
                return 0;
        }
    }

    if ((mask & GL_DEPTH_BUFFER_BIT) && buffers->depth[0].objectType != GL_NONE
        && buffers->depth[1].objectType != GL_NONE && !wk_sameFormat(&buffers->depth[0], &buffers->depth[1]))
        return 0;
    if ((mask & GL_STENCIL_BUFFER_BIT) && buffers->stencil[0].objectType != GL_NONE
        && buffers->stencil[1].objectType != GL_NONE && !wk_sameFormat(&buffers->stencil[0], &buffers->stencil[1]))
        return 0;
    return 1;
}

static void wk_blitFramebuffer(wk_blitFramebufferFunction original,
                               GLint srcX0, GLint srcY0, GLint srcX1, GLint srcY1,
                               GLint dstX0, GLint dstY0, GLint dstX1, GLint dstY1,
                               GLbitfield mask, GLenum filter)
{
    const GLbitfield bufferBits = GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT;
    const GLbitfield depthStencilBits = mask & (GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);

    const char *vendor = depthStencilBits && filter == GL_NEAREST && !(mask & ~bufferBits)
        ? wk_currentContextString(GL_VENDOR) : NULL;
    if (!vendor || strncmp(vendor, "NVIDIA", 6) || !WK_SYSTEM(glIsEnabled)(GL_FRAMEBUFFER_SRGB)) {
        original(srcX0, srcY0, srcX1, srcY1, dstX0, dstY0, dstX1, dstY1, mask, filter);
        return;
    }

    if (mask & GL_COLOR_BUFFER_BIT) {
        struct wk_blitBuffers buffers;
        wk_queryBlitBuffers(&buffers);
        if (wk_srgbAffectsBlitColor(&buffers)) {
            if (!wk_blitHalvesValidSeparately(&buffers, mask)) {
                original(srcX0, srcY0, srcX1, srcY1, dstX0, dstY0, dstX1, dstY1, mask, filter);
                return;
            }
            original(srcX0, srcY0, srcX1, srcY1, dstX0, dstY0, dstX1, dstY1, GL_COLOR_BUFFER_BIT, filter);
            mask = depthStencilBits;
        }
    }

    WK_SYSTEM(glDisable)(GL_FRAMEBUFFER_SRGB);
    original(srcX0, srcY0, srcX1, srcY1, dstX0, dstY0, dstX1, dstY1, mask, filter);
    WK_SYSTEM(glEnable)(GL_FRAMEBUFFER_SRGB);
}

WK_POLYFILL_REPLACES(WK_LIBGL, void, glBlitFramebuffer,
                     (GLint srcX0, GLint srcY0, GLint srcX1, GLint srcY1,
                      GLint dstX0, GLint dstY0, GLint dstX1, GLint dstY1,
                      GLbitfield mask, GLenum filter))
{
    wk_blitFramebuffer(WK_ORIGINAL(glBlitFramebuffer),
                       srcX0, srcY0, srcX1, srcY1, dstX0, dstY0, dstX1, dstY1, mask, filter);
}

WK_POLYFILL_REPLACES(WK_LIBGL, void, glBlitFramebufferEXT,
                     (GLint srcX0, GLint srcY0, GLint srcX1, GLint srcY1,
                      GLint dstX0, GLint dstY0, GLint dstX1, GLint dstY1,
                      GLbitfield mask, GLenum filter))
{
    wk_blitFramebuffer(WK_ORIGINAL(glBlitFramebufferEXT),
                       srcX0, srcY0, srcX1, srcY1, dstX0, dstY0, dstX1, dstY1, mask, filter);
}

// --- glVertexAttribDivisor ----------------------------------------------------------------------
//
// The Apple Software Renderer keeps fetching an enabled array at its previous rate after a divisor
// change (GL 4.1 §2.8 makes the new divisor apply to subsequent draws). It re-reads the rate when
// the array's enable state changes, so an enabled array is disabled and re-enabled after the change.
typedef void (*wk_vertexAttribDivisorFunction)(GLuint, GLuint);

static void wk_vertexAttribDivisor(wk_vertexAttribDivisorFunction original, GLuint index, GLuint divisor)
{
    original(index, divisor);

    const char *renderer = wk_currentContextString(GL_RENDERER);
    if (!renderer || strcmp(renderer, "Apple Software Renderer"))
        return;
    GLint enabled = GL_FALSE;
    WK_SYSTEM(glGetVertexAttribiv)(index, GL_VERTEX_ATTRIB_ARRAY_ENABLED, &enabled);
    if (enabled) {
        WK_SYSTEM(glDisableVertexAttribArray)(index);
        WK_SYSTEM(glEnableVertexAttribArray)(index);
    }
}

WK_POLYFILL_REPLACES(WK_LIBGL, void, glVertexAttribDivisor, (GLuint index, GLuint divisor))
{
    wk_vertexAttribDivisor(WK_ORIGINAL(glVertexAttribDivisor), index, divisor);
}

WK_POLYFILL_REPLACES(WK_LIBGL, void, glVertexAttribDivisorARB, (GLuint index, GLuint divisor))
{
    wk_vertexAttribDivisor(WK_ORIGINAL(glVertexAttribDivisorARB), index, divisor);
}
