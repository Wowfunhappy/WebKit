# A file-promise drag source. Drag from the orange window; every event lands in
# /tmp/file-promise-drag-source.log.
#
#   /usr/bin/python AquaWebKitSupport/tests/file-promise-drag-source.py [legacy|provider] [count]
#
# legacy (the default) is the kind VMware Tools' host-to-guest drag, Mail and iPhoto start:
# -dragPromisedFilesOfTypes:fromRect:source:slideBack:event: promises `count` files (a .txt, then a
# .png), and the files exist once the destination calls -namesOfPromisedFilesDroppedAtDestination:.
# provider drags `count` items through NSFilePromiseProvider -- the polyfill's, found under its private
# runtime name once WebKit is loaded -- whose delegate takes two seconds to write each file, so a
# destination that reads before the write finishes gets a short or missing file.
import ctypes
import os
import sys
import time
import objc
import WebKit
from AppKit import *
from Foundation import *

LOG = '/tmp/file-promise-drag-source.log'
MODE = sys.argv[1] if len(sys.argv) > 1 else 'legacy'
COUNT = int(sys.argv[2]) if len(sys.argv) > 2 else 1
NAMES = [('promised.txt', 'txt', 'public.plain-text', 'promised file contents\n'),
         ('promised.png', 'png', 'public.png', 'not really a png\n')][:COUNT]

def log(message):
    with open(LOG, 'a') as f:
        f.write(message + '\n')

# The completion handler arrives as a block PyObjC cannot call; invoke it through the block ABI.
class _BlockLayout(ctypes.Structure):
    _fields_ = [('isa', ctypes.c_void_p), ('flags', ctypes.c_int), ('reserved', ctypes.c_int), ('invoke', ctypes.c_void_p)]

def callCompletionHandler(block, error):
    address = objc.pyobjc_id(block)
    invoke = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p)(_BlockLayout.from_address(address).invoke)
    invoke(address, objc.pyobjc_id(error) if error is not None else None)

class Delegate(NSObject):
    def init(self):
        self = objc.super(Delegate, self).init()
        self.queue = NSOperationQueue.alloc().init()
        return self

    def operationQueueForFilePromiseProvider_(self, provider):
        return self.queue

    def filePromiseProvider_fileNameForType_(self, provider, fileType):
        return provider.userInfo()

    def filePromiseProvider_writePromiseToURL_completionHandler_(self, provider, url, completionHandler):
        name = provider.userInfo()
        contents = [entry[3] for entry in NAMES if entry[0] == name][0]
        with open(url.path(), 'w') as f:
            f.write(contents[:4])
            f.flush()
            time.sleep(2)
            f.write(contents[4:])
        log('%.3f provider wrote %s' % (time.time(), url.path()))
        callCompletionHandler(completionHandler, None)
        log('%.3f provider completed %s' % (time.time(), url.path()))

class SourceView(NSView):
    def drawRect_(self, rect):
        NSColor.orangeColor().set()
        NSRectFill(self.bounds())

    def draggingSourceOperationMaskForLocal_(self, isLocal):
        return NSDragOperationCopy

    @objc.typedSelector(b'Q@:@q')
    def draggingSession_sourceOperationMaskForDraggingContext_(self, session, context):
        return NSDragOperationCopy

    def draggedImage_endedAt_operation_(self, image, point, operation):
        log('ended operation=%d' % operation)

    @objc.typedSelector(b'v@:@{CGPoint=dd}Q')
    def draggingSession_endedAtPoint_operation_(self, session, point, operation):
        log('ended operation=%d' % operation)

class LegacyView(SourceView):
    def mouseDragged_(self, event):
        self.dragPromisedFilesOfTypes_fromRect_source_slideBack_event_([entry[1] for entry in NAMES], NSMakeRect(10, 10, 32, 32), self, True, event)

    def namesOfPromisedFilesDroppedAtDestination_(self, url):
        for name, extension, uti, contents in NAMES:
            with open(os.path.join(url.path(), name), 'w') as f:
                f.write(contents)
        log('namesOfPromisedFilesDroppedAtDestination: ' + url.path())
        return [entry[0] for entry in NAMES]

class ProviderView(SourceView):
    def mouseDragged_(self, event):
        providerClass = objc.lookUpClass('WKPolyfillPriv_NSFilePromiseProvider')
        items = []
        for name, extension, uti, contents in NAMES:
            provider = providerClass.alloc().initWithFileType_delegate_(uti, self.delegate)
            provider.setUserInfo_(name)
            item = NSDraggingItem.alloc().initWithPasteboardWriter_(provider)
            item.setDraggingFrame_contents_(NSMakeRect(10, 10, 32, 32), NSImage.imageNamed_(NSImageNameMultipleDocuments))
            items.append(item)
        self.beginDraggingSessionWithItems_event_source_(items, event, self)

app = NSApplication.sharedApplication()
app.setActivationPolicy_(NSApplicationActivationPolicyRegular)
window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(NSMakeRect(20, 300, 200, 150), NSTitledWindowMask, NSBackingStoreBuffered, False)
window.setTitle_('File promise source (%s, %d)' % (MODE, COUNT))
view = (LegacyView if MODE == 'legacy' else ProviderView).alloc().initWithFrame_(NSMakeRect(0, 0, 200, 150))
view.delegate = Delegate.alloc().init()
window.setContentView_(view)
window.setLevel_(NSFloatingWindowLevel)
window.makeKeyAndOrderFront_(None)
app.activateIgnoringOtherApps_(True)
app.run()
