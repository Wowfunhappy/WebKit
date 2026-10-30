#pragma D option quiet
#pragma D option strsize=2048

pid$target::__ZN7WebCore16WebSocketChannel4failE*:entry,
pid$target::__ZN7WebCore16WebSocketChannel19didFailSocketStreamE*:entry,
pid$target::__ZN6WebKit16WebSocketChannel15logErrorMessageE*:entry
{ self->webSocketError++; }

pid$target::__ZN7WebCore16WebSocketChannel4failE*:return,
pid$target::__ZN7WebCore16WebSocketChannel19didFailSocketStreamE*:return,
pid$target::__ZN6WebKit16WebSocketChannel15logErrorMessageE*:return
{ self->webSocketError--; }

/* The console text includes the URL and reason, materialized by the WebSocket caller. */
pid$target::__ZN7WebCore8Document17addConsoleMessageEN3JSC13MessageSourceENS1_12MessageLevelERKN3WTF6StringEm:entry
/self->webSocketError && arg3 != 0/
{
    this->impl = *(uintptr_t *)copyin(arg3, 8);
    this->length = this->impl ? *(uint32_t *)copyin(this->impl + 4, 4) : 0;
    this->data = this->impl ? *(uintptr_t *)copyin(this->impl + 8, 8) : 0;
    this->flags = this->impl ? *(uint32_t *)copyin(this->impl + 16, 4) : 0;
    printf("%d\t%s\t%s\n", pid, probefunc,
        (this->flags & 4) && this->length ? copyinstr(this->data, this->length < 1024 ? this->length : 1024) : "<UTF16-or-empty>");
}

BEGIN { printf("READY %d\n", $target); }
